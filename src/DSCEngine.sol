//SPDX-License-Identifier: MIT
// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
/**
 * @title DSCEngine
 * @author ALvan
 * This sysrtem is designed to be as minimal as possible, and we have  the tokens maintain a 1 token = $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees ad we all backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value
 * of all the collateral <= the $ backed value of all the DSC.
 * @notice This contract is the cire if the DSC System. It handles all the logic for mining
 * and redeeming DSC, as well as depositing & withdrawing collateral
 * @notice This conctract is VERY loosely based on the MAkerDAO DSS (DAI) System.
 */

contract DSCEngine is ReentrancyGuard {
    //////////////
    // Errors   //
    /////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeTheSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFaile();

    ///////////////////////
    // State Variables   //
    //////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    DecentralizedStableCoin private immutable i_dsc;
    address[] private s_collaterlaTokens;

    ////////////////
    // Events     //
    ///////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    /////////////////
    // Modifiers  //
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////
    // Functions   //
    /////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeTheSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collaterlaTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    /////////////////////////
    function depositCollateralAndMintDsc() external {}

    /*
    * @param TokenCollateralAddress the address of the toke to deposit as collateral
    * @param amountCollatral The amount of collateral for deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountSdcToMint);
        if(!minted){
            revert DSCEngine__MintFaile();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    /////////////////////////////////////////
    // Private & internal View Functions  //
    ////////////////////////////////////////

    function _getAccpountInformation(address user)
        private
        view
        returns (uint256 amountDscMinted, uint256 collateralValueInUsd)
    {
        amountDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns hwo close to liquation a user is 
     * If a user goes below 1, then they are can get liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        // check total DSC minted
        // Total collateral VALUE
        // Collateral: 1000 ETH * 50 (LIQUIDATION_THRESHOLD) = 50,000 / 100 (LIQUIDATION_PRECISION)= 500
        // Collateral / DSC  must be  greater than 1

        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50000/100 = (500/100)
        (uint256 amountMinted, uint256 collateralValueInUsd) = _getAccpountInformation(user);

        uint256 collateralAdjustedForThreshol = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshol * PRECISION) / amountMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // Check health factor (do they have enough collateral?)
        // Revert if they don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
    /////////////////////////////////////////
    // Public & External View Functions   //
    ///////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueUsd) {
        for (uint256 i = 0; i < s_collaterlaTokens.length; i++) {
            address token = s_collaterlaTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // if 1ETH = $1000
        // The returned vakue from cl will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
