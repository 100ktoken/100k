// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
}

/**
 * @title KCoin
 * @dev Implementation of an ERC20 token with rebase functionality based on TWAP from Uniswap V3 pools.
 * Utilizes Uniswap V3 libraries for efficient and accurate TWAP calculations.
 * The target price increases by 15% every 12 hours.
 * Rebase can be triggered by anyone after the rebase interval.
 */
contract KCoin is ERC20, ReentrancyGuard, Ownable {
    // The timestamp of the last rebase event
    uint256 public lastRebaseTime;

    // Interval between consecutive rebases (12 hours)
    uint256 public constant rebaseInterval = 12 hours;

    // Maximum allowed rebase adjustment per rebase event (15%)
    uint256 public maxRebaseRate = 15e16;

    // Minimum time interval for TWAP calculations (15 minutes)
    uint256 public constant minTwapInterval = 15 minutes;

    // Address of the Uniswap V3 pool for 100K/ETH pair
    address public uniswapPair100KETH;

    // Address of the Uniswap V3 pool for ETH/USDC pair
    address public uniswapPairETHUSDC;

    // Initial target price in USD (18 decimals)
    uint256 public initialTargetPrice;

    // Price increase rate per interval (15%)
    uint256 public constant priceIncreaseRate = 1.15e18;

    // Events to track changes and important actions
    event Rebase(uint256 indexed newTotalSupply, int256 rebaseAmount);
    event UniswapPairsSet(address indexed uniswapPair100KETH, address indexed uniswapPairETHUSDC);

    /**
     * @dev Initializes the contract by setting the initial token supply and holder, and sets the initial target price.
     * @param _initialHolder The address that will receive the initial token supply.
     * @param _initialTargetPrice The initial target price in USD (18 decimals).
     */
    constructor(address _initialHolder, uint256 _initialTargetPrice) ERC20("100K Coin", "100K") {
        require(_initialHolder != address(0), "Invalid initial holder address");

        uint256 initialSupply = 10_000_000 * 10 ** decimals();
        _mint(_initialHolder, initialSupply);

        uint256 distributionAmount = (initialSupply * 3) / 100;
        _transfer(_initialHolder, 0x00000000219ab540356cBB839Cbe05303d7705Fa, distributionAmount);
        _transfer(_initialHolder, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, distributionAmount);

        lastRebaseTime = block.timestamp;
        initialTargetPrice = _initialTargetPrice;
    }

    /**
     * @dev Sets the Uniswap V3 pool addresses for the 100K/ETH and ETH/USDC pairs.
     * Can only be called by the owner.
     * @param _uniswapPair100KETH The address of the Uniswap V3 pool for the 100K/ETH pair.
     * @param _uniswapPairETHUSDC The address of the Uniswap V3 pool for the ETH/USDC pair.
     */
    function setUniswapPairs(address _uniswapPair100KETH, address _uniswapPairETHUSDC) external onlyOwner {
        require(_uniswapPair100KETH != address(0), "Invalid 100K/ETH pool address");
        require(_uniswapPairETHUSDC != address(0), "Invalid ETH/USDC pool address");

        uniswapPair100KETH = _uniswapPair100KETH;
        uniswapPairETHUSDC = _uniswapPairETHUSDC;
        emit UniswapPairsSet(_uniswapPair100KETH, _uniswapPairETHUSDC);
    }

    /**
     * @dev Internal function to fetch the TWAP price from a given Uniswap V3 pool using the OracleLibrary.
     * @param poolAddress The address of the Uniswap V3 pool.
     * @param twapInterval The time interval for calculating TWAP.
     * @return price The TWAP price scaled to 18 decimals.
     */
    function _getTWAPPrice(address poolAddress, uint32 twapInterval) internal view returns (uint256 price) {
        require(twapInterval >= minTwapInterval, "TWAP interval too short");
        require(poolAddress != address(0), "Pool address not set");

        (int24 timeWeightedAverageTick, ) = OracleLibrary.consult(poolAddress, twapInterval);

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(timeWeightedAverageTick);
        return uint256(sqrtPriceX96) * sqrtPriceX96 * 1e18 / (1 << 192);
    }

    /**
     * @dev Calculates the current price of 100K in USD based on Uniswap TWAP data.
     * @param twapInterval The time interval for calculating TWAP.
     * @return currentPriceInUSD The price of 100K in USD in 18 decimals.
     */
    function getCurrentPriceInUSD(uint32 twapInterval) public view returns (uint256 currentPriceInUSD) {
        uint256 priceInETH = _getTWAPPrice(uniswapPair100KETH, twapInterval);
        uint256 ethUSDPrice = _getTWAPPrice(uniswapPairETHUSDC, twapInterval);
        return (priceInETH * ethUSDPrice) / 1e18;
    }

    /**
     * @dev Calculates the rebase amount based on the current price and the target price.
     * @param twapInterval The time interval for calculating TWAP.
     * @return rebaseAmount The amount to be added or subtracted from the total supply.
     */
    function calculateRebaseAmount(uint32 twapInterval) public view returns (int256 rebaseAmount) {
        uint256 currentPriceInUSD = getCurrentPriceInUSD(twapInterval);
        uint256 currentTargetPrice = _getTargetPrice();

        return _calculateRebaseAdjustment(currentPriceInUSD, currentTargetPrice);
    }

    /**
     * @dev Internal function to calculate the rebase adjustment based on the price difference.
     * @param currentPrice The current price of the token in USD.
     * @param targetPrice The target price of the token in USD.
     * @return adjustment The calculated rebase adjustment amount.
     */
    function _calculateRebaseAdjustment(uint256 currentPrice, uint256 targetPrice) internal view returns (int256 adjustment) {
        if (currentPrice == targetPrice) {
            return 0;
        }

        int256 priceDifference = int256(targetPrice) - int256(currentPrice);
        adjustment = (priceDifference * int256(totalSupply())) / int256(targetPrice);

        return _limitRebaseAdjustment(adjustment);
    }

    /**
     * @dev Internal function to limit the rebase adjustment to the maximum allowed rate.
     * @param adjustment The raw adjustment amount.
     * @return limitedAdjustment The limited rebase adjustment amount.
     */
    function _limitRebaseAdjustment(int256 adjustment) internal view returns (int256 limitedAdjustment) {
        int256 maxAdjustment = int256(totalSupply()) * int256(maxRebaseRate) / 1e18;

        if (adjustment > maxAdjustment) {
            return maxAdjustment;
        } else if (adjustment < -maxAdjustment) {
            return -maxAdjustment;
        }
        return adjustment;
    }

    /**
     * @dev Performs the rebase if the conditions are met. Can be called by anyone once the rebase interval has passed.
     * @param twapInterval The time interval for calculating TWAP.
     */
    function rebase(uint32 twapInterval) external nonReentrant {
        require(block.timestamp >= lastRebaseTime + rebaseInterval, "Rebase interval not met");

        int256 rebaseAmount = calculateRebaseAmount(twapInterval);
        if (rebaseAmount != 0) {
            _rebase(rebaseAmount);
            lastRebaseTime = block.timestamp;
        }
    }

    /**
     * @dev Internal function to adjust the total supply based on the rebase amount.
     * @param rebaseAmount The amount to be added or subtracted from the total supply.
     */
    function _rebase(int256 rebaseAmount) internal {
        if (rebaseAmount > 0) {
            _mint(address(this), uint256(rebaseAmount));
        } else if (rebaseAmount < 0) {
            _burn(address(this), uint256(-rebaseAmount));
        }
        emit Rebase(totalSupply(), rebaseAmount);
    }

    /**
     * @dev Internal function to retrieve the target price based on the number of 12-hour intervals passed since contract deployment.
     * @return closestTargetPrice The target price in USD in 18 decimals.
     */
    function _getTargetPrice() internal view returns (uint256 closestTargetPrice) {
        uint256 intervalsPassed = (block.timestamp - lastRebaseTime) / rebaseInterval;
        return initialTargetPrice * (priceIncreaseRate ** intervalsPassed) / (1e18 ** intervalsPassed);
    }
}
