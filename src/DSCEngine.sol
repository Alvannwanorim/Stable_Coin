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
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
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
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    ///////////////////////
    // State Variables   //
    //////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    DecentralizedStableCoin private immutable i_dsc;
    address[] private s_collaterlaTokens;

    ////////////////
    // Events     //
    ///////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
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

    /*
     * @param tokenCollateralAddress The adress of the token to be deposited as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stable-coin to mint
     * @notice this function will deposit and mint DSC in one transfer
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
    * @param TokenCollateralAddress the address of the toke to deposit as collateral
    * @param amountCollatral The amount of collateral for deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
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

    /*
     * @param tokenCollateralAddress The address of the token to redeem 
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToMint The amount of decentralized stable-coin to burn
     * @notice this function will redeem and burn DSC in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // In order to redeem Collateral
    // 1. Health factor must be over 1 After collateral pulled
    // CEI Check, Effects, Interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // This may never hit
    }

    // If we do start nearing undercollateralization, we need someone to liduate their possessions

    // $100 ETH backing $50 DSC
    // 20 ETH backing $50 DSC <- DSC isn't woth &1!!!

    //$75 backing $50 DSC
    // Liquidator take $75 backing anf burns off the $50 DSC

    // if someone is almost undercollateralized, we will pay you liquaiate them

    /*
     * @param collateral the ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healtFactor should below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to pay to burn to improve the user health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice A known bug would be if the protocal were 100% or less collateralized, 
     * then we wouldn;t be able to incentive the liquidators
     * For example, if the price of the collateral plummeted before anyone couls be liquidated.
     * Follow CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //need to check health factor for the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn their DSC "debt"
        // And take their collaterals
        // Bad User: $140 ETH, 100 DSC
        // debtToCover = $100
        // $100 of DSC == ?? ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator  $110 of WETH for 100
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts inot a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////////////
    // Private & internal View Functions  //
    ////////////////////////////////////////

    /*
     * @dev Low-levl internal function, do not call unless the function it is 
     * checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 amountDscMinted, uint256 collateralValueInUsd)
    {
        amountDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        private
        view
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAjustedForThreshhold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAjustedForThreshhold * 1e18) / totalDscMinted;
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
        (uint256 amountMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

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

      function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // if 1ETH = $1000
        // The returned vakue from cl will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
    /////////////////////////////////////////
    // Public & External View Functions   //
    ///////////////////////////////////////

function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external view returns (uint256) {
    return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);

}
       
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH ??
        // $2000 /ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueUsd) {
        for (uint256 i = 0; i < s_collaterlaTokens.length; i++) {
            address token = s_collaterlaTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueUsd)
    {
        (totalDscMinted, collateralValueUsd) = _getAccountInformation(user);
    }

    function getCollateralBalanceOfUser(address user, address toke) public view returns(uint256) {
        return s_collateralDeposited[user][token];
    } 
    function getPrecision() external pure returns(uint256) {
        return PRECISION;
    }
    function getAdditionalFeedPrecision() external pure returns(uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }
    function getLiquidationThreshold()external pure returns(uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns(uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns(uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns(uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns(address[] memory){
        return s_collaterlaTokens;
    }

    function getDsc() external view returns(address) {
        return address(i_dsc);
    }

    function getCollateralTokenFeedPrice(address token) external view returns(address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns(uint256) {
        return _healthFactor(user);
    }

}
