// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IVault {
  function reserve() external view returns (address);

  function deposit(uint256) external returns (bool);

  function redeem(uint256) external returns (bool);

  // @dev Must return the total balance in reserve.
  function getBalance() external view returns (uint256);
}
