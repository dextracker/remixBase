// SPDX-License-Identifier: ISC
pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "./DydxFlashloanBase.sol";
import "./ICallee.sol";
import {KyberNetworkProxy as IKyberNetworkProxy} from "./KyberNetworkProxy.sol";

import "./IERC20.sol";
import "./IUniswapV2Router02.sol";
import "./IWeth.sol";

contract Flashloan is ICallee, DydxFlashloanBase {
  enum Direction {KyberToUniswap, UniswapToKyber}
  struct ArbInfo {
    Direction direction;
    uint256 repayAmount;
  }

  event NewArbitrage(Direction indexed direction, uint256 indexed profit, uint256 indexed date);

  // events for debugging
  // event GetMinOuts(uint256 indexed minOut1, uint256 indexed minOut2);

  IKyberNetworkProxy kyber;
  IUniswapV2Router02 uniswap;
  IWeth weth;
  IERC20 dai;
  address beneficiary;
  address constant KYBER_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  constructor(
    address kyberAddress,
    address uniswapAddress,
    address wethAddress,
    address daiAddress,
    address beneficiaryAddress
  ) public {
    kyber = IKyberNetworkProxy(kyberAddress);
    uniswap = IUniswapV2Router02(uniswapAddress);
    weth = IWeth(wethAddress);
    dai = IERC20(daiAddress);
    beneficiary = beneficiaryAddress;
  }

  // This is the function that will be called postLoan
  // i.e. Encode the logic to handle your flashloaned funds here
  function callFunction(
    address sender,
    Account.Info memory account,
    bytes memory data
  ) public {
    ArbInfo memory arbInfo = abi.decode(data, (ArbInfo));
    uint256 balanceDai = dai.balanceOf(address(this));
    uint256 deadline = now + 300;

    if (arbInfo.direction == Direction.KyberToUniswap) {
      // Buy ETH from Kyber
      require(dai.approve(address(kyber), balanceDai), "Could not approve reserve asset sell!");
      (uint256 expectedRate, ) = kyber.getExpectedRate(dai, IERC20(KYBER_ETH_ADDRESS), balanceDai);
      kyber.swapTokenTo/Ether(dai, balanceDai, expectedRate);

      // Sell ETH to Uniswap
      address[] memory path = new address[](2);
      path[0] = address(weth);
      path[1] = address(dai);

      // https://uniswap.org/docs/v2/smart-contracts/library#getamountsout
      // Given an input asset amount and an array of token addresses, calculates all subsequent maximum output token amounts
      uint256[] memory minOuts = uniswap.getAmountsOut(address(this).balance, path);

      // https://uniswap.org/docs/v2/smart-contracts/router02/
      // Swaps an exact amount of ETH for as many output tokens as possible, along the route determined by the path.
      // The first element of path must be WETH, the last is the output token
      uniswap.swapExactETHForTokens.value(address(this).balance)(minOuts[1], path, address(this), deadline);
    } else {
      // Buy ETH from Uniswap
      require(dai.approve(address(uniswap), balanceDai), "Could not approve reserve asset sell!");
      address[] memory path = new address[](2);
      path[0] = address(dai);
      path[1] = address(weth);
      uint256[] memory minOuts = uniswap.getAmountsOut(balanceDai, path);
      uniswap.swapExactTokensForETH(balanceDai, minOuts[1], path, address(this), deadline);
      // Sell ETH to Kyber
      (uint256 expectedRate, ) = kyber.getExpectedRate(IERC20(KYBER_ETH_ADDRESS), dai, address(this).balance);
      kyber.swapEtherToToken.value(address(this).balance)(dai, expectedRate);
    }

    balanceDai = dai.balanceOf(address(this));
    require(balanceDai - arbInfo.repayAmount >= 0, "Not enough funds to repay dydx loan!");

    uint256 profit = balanceDai - arbInfo.repayAmount;
    require(dai.transfer(beneficiary, profit), "Could not transfer back the profit!");

    emit NewArbitrage(arbInfo.direction, profit, now);
  }

  function initateFlashLoan(
    address _solo,
    address _token,
    uint256 _amount,
    Direction _direction
  ) external {
    // Get marketId from token address
    uint256 marketId = _getMarketIdFromTokenAddress(_solo, _token);

    // Calculate repay amount (_amount + (2 wei))
    // Approve transfer from
    uint256 repayAmount = _getRepaymentAmountInternal(_amount);
    IERC20(_token).approve(_solo, repayAmount);

    // 1. Withdraw $
    // 2. Call callFunction(...)
    // 3. Deposit back $
    Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3);

    operations[0] = _getWithdrawAction(marketId, _amount);
    operations[1] = _getCallAction(
      // Encode MyCustomData for callFunction
      abi.encode(ArbInfo({direction: _direction, repayAmount: repayAmount}))
    );
    operations[2] = _getDepositAction(marketId, repayAmount);

    Account.Info[] memory accountInfos = new Account.Info[](1);
    accountInfos[0] = _getAccountInfo();

    ISoloMargin(_solo).operate(accountInfos, operations);
  }

  // Add payable function to be able to receive ETH from Uniswap / Kyber
  function() external payable {}
}
