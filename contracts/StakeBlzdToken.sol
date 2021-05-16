// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract StakeBlzdToken is ERC20 {
  constructor(address _snowVault) public ERC20('BLZD Staker Token', 'BLZDST') {
     _mint(_snowVault, 100e18);
  }
}
