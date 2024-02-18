//SPDX-License-Identifer: MIT

pragma solidity ^0.8.19;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Invaraints is StdInvariant, Test {
    DeployDSC public deployer;
    DSCEngine public dsce;
    DecentralizedStableCoin  public dsc;
    HelperConfig  public config; 
    address public weth;
    address public wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        targetContract(address(dsce));
    }

    function invariantProtocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited); 
        uint256 wbetcValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

        assert(wethValue + wbetcValue >= totalSupply);

    }


} 