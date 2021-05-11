// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/**
 * This interface is only to facilitate
 * interacting with the contract in remix.ethereum.org
 * after it has been deployed to a testnet or mainnet.
 *
 * Just copy/paste the interface in Remix and deploy
 * at contract address.
 */

interface ISnowBank {
  function TAX() external view returns (uint256);

  function DIVIDER() external view returns (uint256);

  function gale() external view returns (address);

  function totalInterestClaimed() external view returns (uint256);

  function totalReserve() external view returns (uint256);

  function reserve() external view returns (address);

  function vault() external view returns (address);

  function invest(uint256) external;

  function sell(uint256) external;

  function claimInterest() external;

  function totalClaimRequired() external view returns (uint256);

  function claimRequired(uint256) external view returns (uint256);

  function totalContributed() external view returns (uint256);

  function getInterest() external view returns (uint256);

  function getTotalSupply() external view returns (uint256);

  function getBurnedTokensAmount() external view returns (uint256);

  function getCurrentTokenPrice() external view returns (uint256);

  function getReserveToTokensTaxed(uint256) external view returns (uint256);

  function getTokensToReserveTaxed(uint256) external view returns (uint256);

  function getReserveToTokens(uint256) external view returns (uint256);

  function getTokensToReserve(uint256) external view returns (uint256);
}
