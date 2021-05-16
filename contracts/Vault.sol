// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './interfaces/IVault.sol';
import './interfaces/IVaultAlpaca.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

contract Vault is IVault, Ownable ,ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  /// @notice BUSD address.
  address public override reserve;

  /// @notice address of Alpaca Vault contract.
  address public alpacaVaultAddress;

  /// @notice Balance tracker of accounts who have deposited funds.
  mapping(address => uint256) balance;

  /// @notice Is SnowBank
  mapping(address => bool) snowBank;

  event AddSnowBank(address indexed snowBank);
  event RemoveSnowBank(address indexed snowBank);

  constructor(address _reserve, address _alpacaVaultAddress) public {
    reserve = _reserve;
    alpacaVaultAddress = _alpacaVaultAddress;
    _approveMax(reserve, _alpacaVaultAddress);
  }

  modifier onlySnowBank() {
      require(snowBank[msg.sender] , "Caller is not SnowBank Contract");
      _;
  }

  /// @notice Deposits reserve into savingsAccount.
  /// @dev It is part of Vault's interface.
  /// @param amount Value to be deposited.
  /// @return True if successful.
  function deposit(uint256 amount) external override onlySnowBank returns (bool) {
    require(amount > 0, 'Amount must be greater than 0');

    IERC20(reserve).safeTransferFrom(msg.sender, address(this), amount);
    balance[msg.sender] = balance[msg.sender].add(amount);

    _sendToSavings(amount);

    return true;
  }

  /// @notice Redeems reserve from savingsAccount.
  /// @dev It is part of Vault's interface.
  /// @param amount Value to be redeemed.
  /// @return True if successful.
  function redeem(uint256 amount) external override nonReentrant onlySnowBank returns (bool) {
    require(amount > 0, 'Amount must be greater than 0');
    require(amount <= balance[msg.sender], 'Not enough funds');

    balance[msg.sender] = balance[msg.sender].sub(amount);

    _redeemFromSavings(msg.sender, amount);

    return true;
  }

  /// @notice Returns balance in reserve from the savings contract.
  /// @dev It is part of Vault's interface.
  /// @return _balance Reserve amount in the savings contract.
  function getBalance() public override view returns (uint256 _balance) {
    IVaultAlpaca IAlpaca = IVaultAlpaca(alpacaVaultAddress);
    _balance = IAlpaca.balanceOf(address(this)).mul(IAlpaca.totalToken()).div(IAlpaca.totalSupply());
  }

  function _approveMax(address token, address spender) internal {
    uint256 max = uint256(-1);
    IERC20(token).safeApprove(spender, max);
  }

  // @notice Worker function to send funds to savings account.
  // @param _amount The amount to send.
  function _sendToSavings(uint256 _amount) internal {
    if (IERC20(reserve).allowance(address(this), alpacaVaultAddress) < _amount) {
      _approveMax(reserve, alpacaVaultAddress);
    }

    IVaultAlpaca(alpacaVaultAddress).deposit(_amount);
  }

  // @notice Worker function to redeems funds from savings account.
  // @param _account The account to redeem to.
  // @param _amount The amount to redeem.
  function _redeemFromSavings(address _account, uint256 _amount) internal {

    IVaultAlpaca IAlpaca = IVaultAlpaca(alpacaVaultAddress);
    
    uint256 shareAmount = _amount.mul(IAlpaca.totalSupply()).div(IAlpaca.totalToken());
    
    IVaultAlpaca(alpacaVaultAddress).withdraw(shareAmount);
    
    IERC20(reserve).safeTransfer(_account, IERC20(reserve).balanceOf(address(this)));
  }

 function addSnowBank(address _snowBank) public onlyOwner {
    snowBank[_snowBank] = true;
    emit AddSnowBank(_snowBank);
  }

  function removeSnowBank(address _snowBank) public onlyOwner {
    snowBank[_snowBank] = false;
    emit RemoveSnowBank(_snowBank);
  }

}
