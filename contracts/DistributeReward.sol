// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract DistributeBUSD {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IERC20 public BUSD = IERC20(0x000000000000000000000);

    //TODO
    address public blzdPool;
    address public gasFee;
    address public team;

    function distribute() external {
        uint256 balance = BUSD.balanceOf(address(this));
        uint256 blzdPoolAmount = balance.mul(300).div(500);
        uint256 gasFeeAmount = balance.mul(50).div(500);
        uint256 teamAmount =  (balance.sub(blzdPoolAmount)).sub(gasFeeAmount);
        BUSD.transfer(blzdPool, blzdPoolAmount);
        BUSD.transfer(gasFee, gasFeeAmount);
        BUSD.transfer(team, teamAmount);
        // BUSD.transfer(team, balance);
    }
}
