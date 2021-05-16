// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './GaleToken.sol';
import './interfaces/IVault.sol';
import './interfaces/ISnowBank.sol';
import './utils/MathUtils.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SnowBank
contract SnowBank is ISnowBank, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using MathUtils for uint256;
    using SafeERC20 for IERC20;

    event TokensBought(address indexed from, uint256 amountInvested, uint256 tokensMinted);
    event TokensSold(address indexed from, uint256 tokensSold, uint256 amountReceived);
    event MintAndBurn(uint256 reserveAmount, uint256 tokensBurned);
    event InterestClaimed(address indexed from, uint256 initerestAmount);
    event AddSnowBankVault(address indexed snowVaults);
    event RemoveSnowBankVault(address indexed snowVault);

    /// @notice A 3% tax is applied to every purchase or sale of tokens.
    uint256 public constant override TAX = 3;

    /// @notice The slope of the bonding curve.
    uint256 public constant override DIVIDER = 1000000; // 1 / multiplier 0.000001 (so that we don't deal with decimals) // TODO

    /// @notice Address in which tokens are sent to be burned.
    /// @dev These tokens can't be redeemed by the reserve.
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice GaleToken token instance.
    GaleToken public immutable token;

    /// @notice Total interests earned since the contract deployment.
    uint256 public override totalInterestClaimed;

    /// @notice Total reserve value that backs all tokens in circulation.
    /// @dev Area below the bonding curve.
    uint256 public override totalReserve;

    /// @notice BUSD reserve instance.
    address public immutable override reserve;

    /// @notice Interface for integration with lending platform.
    address public immutable override vault;

    mapping (address => bool) public snowBankVault;

    modifier onlySnowBankVault() {
        require(snowBankVault[msg.sender] , "Caller is not SnowBankVault contract");
        _;
    }
  
    constructor(address _vault) public {
      vault = _vault;
      address _reserve = IVault(_vault).reserve();
      token = new GaleToken(address(this));
      reserve = _reserve;
      _approveMax(_reserve, _vault);
    }

    /// @notice gale address
    /// @return gale address
    function gale() public override view returns (address) {
      return address(token);
    }

    /// @notice Exchanges reserve to tokens according to the bonding curve formula.
    /// @dev Amount to be invested needs to be approved first.
    /// @param reserveAmount Value in wei that will be exchanged to tokens.
    function invest(uint256 reserveAmount) external override onlySnowBankVault {
      _invest(reserveAmount);
    }

    /// @notice Exchanges token for reserve according to the bonding curve formula.
    /// @param tokenAmount Token value in wei that will be exchanged to reserve
    function sell(uint256 tokenAmount) external override {
      _sell(tokenAmount);
    }

    /// @notice Sells the maximum amount of tokens required to claim the most interest.
    function claimInterest() external override {
      uint256 balance = token.balanceOf(msg.sender);
      uint256 totalRequired = totalClaimRequired();
      uint256 totalToClaim = balance < totalRequired ? balance : totalRequired;
      _sell(totalToClaim);
    }

    /// @notice Calculates the amount of tokens required to claim a specific interest amount.
    /// @param amountToClaim Interest amount to be claimed.
    /// @return Amount of tokens required to claim all specified interest.
    function claimRequired(uint256 amountToClaim) external override view returns (uint256) {
      return _calculateClaimRequired(amountToClaim);
    }

    /// @notice Calculates the amount of tokens required to claim the outstanding interest.
    /// @return Amount of tokens required to claim all the outstanding interest.
    function totalClaimRequired() public override view returns (uint256) {
      return _calculateClaimRequired(getInterest());
    }

    /// @notice Total amount that has been paid in Taxes
    /// and is now forever locked in the protocol.
    function totalContributed() external override view returns (uint256) {
      return _calculateReserveFromSupply(getBurnedTokensAmount());
    }

    /// @notice Total outstanding interest accumulated.
    /// @return interest Interest in reserve accumulated in lending protocol.
    function getInterest() public override view returns (uint256 interest) {
      uint256 vaultBalance = IVault(vault).getBalance();
      // Sometimes mStable returns a value lower than the
      // deposit because their exchange rate gets updated after the deposit.
      if (vaultBalance > totalReserve) {
        interest = vaultBalance - totalReserve;
      }
    }

    /// @notice Total supply of tokens. This includes burned tokens.
    /// @return Total supply of token in wei.
    function getTotalSupply() public override view returns (uint256) {
      return token.totalSupply();
    }

    /// @notice Total tokens that have been burned.
    /// @dev These tokens are still in circulation therefore they
    /// are still considered on the bonding curve formula.
    /// @return Total burned token amount in wei.
    function getBurnedTokensAmount() public override view returns (uint256) {
      return token.balanceOf(BURN_ADDRESS);
    }

    /// @notice Token's price in wei according to the bonding curve formula.
    /// @return Current token price in wei.
    function getCurrentTokenPrice() external override view returns (uint256) {
      // price = supply * multiplier
      return getTotalSupply().roundedDiv(DIVIDER);
    }

    /// @notice Calculates the amount of tokens in exchange for reserve after applying the 3% tax.
    /// @param reserveAmount Reserve value in wei to use in the conversion.
    /// @return Token amount in wei after the 3% tax has been applied.
    function getReserveToTokensTaxed(uint256 reserveAmount) external override view returns (uint256) {
      if (reserveAmount == 0) {
        return 0;
      }
      uint256 fee = reserveAmount.mul(TAX).div(100);
      uint256 totalTokens = getReserveToTokens(reserveAmount);
      uint256 taxedTokens = getReserveToTokens(fee);
      return totalTokens.sub(taxedTokens);
    }

    /// @notice Calculates the amount of reserve in exchange for tokens after applying the 10% tax.
    /// @param tokenAmount Token value in wei to use in the conversion.
    /// @return Reserve amount in wei after the 3% tax has been applied.
    function getTokensToReserveTaxed(uint256 tokenAmount) external override view returns (uint256) {
      if (tokenAmount == 0) {
        return 0;
      }
      uint256 reserveAmount = getTokensToReserve(tokenAmount);
      uint256 fee = reserveAmount.mul(TAX).div(100);
      return reserveAmount.sub(fee);
    }

    /// @notice Calculates the amount of tokens in exchange for reserve.
    /// @param reserveAmount Reserve value in wei to use in the conversion.
    /// @return Token amount in wei.
    function getReserveToTokens(uint256 reserveAmount) public override view returns (uint256) {
      return _calculateReserveToTokens(reserveAmount, totalReserve, getTotalSupply());
    }

    /// @notice Calculates the amount of reserve in exchange for tokens.
    /// @param tokenAmount Token value in wei to use in the conversion.
    /// @return Reserve amount in wei.
    function getTokensToReserve(uint256 tokenAmount) public override view returns (uint256) {
      return _calculateTokensToReserve(tokenAmount, getTotalSupply(), totalReserve);
    }

    /// @notice Worker function that exchanges reserve to tokens.
    /// Extracts 3% fee from the reserve supplied and exchanges the rest to tokens.
    /// Total amount is then sent to the lending protocol so it can start earning interest.
    /// @dev User must approve the reserve to be spent before investing.
    /// @param _reserveAmount Total reserve value in wei to be exchanged to tokens.
    function _invest(uint256 _reserveAmount) internal nonReentrant {
      uint256 fee = _reserveAmount.mul(TAX).div(100);
      require(fee >= 1, 'Transaction amount not sufficient to pay fee');

      uint256 totalTokens = getReserveToTokens(_reserveAmount);
      uint256 taxedTokens = getReserveToTokens(fee);
      uint256 userTokens = totalTokens.sub(taxedTokens);

      require(taxedTokens > 0, 'This is not enough to buy a token');

      IERC20(reserve).safeTransferFrom(msg.sender, address(this), _reserveAmount);

      if (IERC20(reserve).allowance(address(this), vault) < _reserveAmount) {
        _approveMax(reserve, vault);
      }

      require(IVault(vault).deposit(_reserveAmount), 'Vault deposit failed');

      totalReserve = totalReserve.add(_reserveAmount);

      token.mint(BURN_ADDRESS, taxedTokens);
      token.mint(msg.sender, userTokens);

      emit TokensBought(msg.sender, _reserveAmount, userTokens);
      emit MintAndBurn(fee, taxedTokens);
    }

    /// @notice Worker function that exchanges token for reserve.
    /// Tokens are decreased from the total supply according to the bonding curve formula.
    /// A 10% tax is applied to the reserve amount. 90% is retrieved
    /// from the lending protocol and sent to the user and 10% is used to mint and burn tokens.
    /// @param _tokenAmount Token value in wei that will be exchanged to reserve.
    function _sell(uint256 _tokenAmount) internal nonReentrant {
      require(_tokenAmount <= token.balanceOf(msg.sender), 'Insuficcient balance');
      require(_tokenAmount > 0, 'Must sell something');

      uint256 reserveAmount = getTokensToReserve(_tokenAmount);
      uint256 fee = reserveAmount.mul(TAX).div(100);

      require(fee >= 1, 'Must pay minimum fee');

      uint256 net = reserveAmount.sub(fee);
      uint256 taxedTokens = _calculateReserveToTokens(
        fee,
        totalReserve.sub(reserveAmount),
        getTotalSupply().sub(_tokenAmount)
      );
      uint256 claimable = _calculateClaimableAmount(reserveAmount);
      uint256 totalClaim = net.add(claimable);

      totalReserve = totalReserve.sub(net);
      totalInterestClaimed = totalInterestClaimed.add(claimable);

      token.decreaseSupply(msg.sender, _tokenAmount);
      token.mint(BURN_ADDRESS, taxedTokens);

      IVault(vault).redeem(totalClaim);
      IERC20(reserve).safeTransfer(msg.sender, IERC20(reserve).balanceOf(address(this)));

      emit TokensSold(msg.sender, _tokenAmount, net);
      emit MintAndBurn(fee, taxedTokens);
      emit InterestClaimed(msg.sender, claimable);
    }

    function _approveMax(address tkn, address spender) internal {
      uint256 max = uint256(-1);
      IERC20(tkn).safeApprove(spender, max);
    }

    /// @notice Calculates the tokens required to claim a specific amount of interest.
    /// @param _amount The interest to be claimed.
    /// @return The amount of tokens in wei that are required to claim the interest.
    function _calculateClaimRequired(uint256 _amount) internal view returns (uint256) {
      uint256 newReserve = totalReserve.sub(_amount);
      uint256 newReserveSupply = _calculateReserveToTokens(newReserve, 0, 0);
      return getTotalSupply().sub(newReserveSupply);
    }

    /// @notice Calculates the maximum amount of interest that can be claimed
    /// given a certain value.
    /// @param _amount Value to be used in the calculation.
    /// @return _claimable The interest amount in wei that can be claimed for the given value.
    function _calculateClaimableAmount(uint256 _amount) internal view returns (uint256 _claimable) {
      uint256 interest = getInterest();
      _claimable = _amount > interest ? interest : _amount;
    }

    /**
     * Supply (s), reserve (r) and token price (p) are in a relationship defined by the bonding curve:
     *      p = m * s
     * The reserve equals to the area below the bonding curve
     *      r = s^2 / 2
     * The formula for the supply becomes
     *      s = sqrt(2 * r / m)
     *
     * In solidity computations, we are using divider instead of multiplier (because its an integer).
     * All values are decimals with 18 decimals (represented as uints), which needs to be compensated for in
     * multiplications and divisions
     */

    /// @notice Computes the increased supply given an amount of reserve.
    /// @param _reserveDelta The amount of reserve in wei to be used in the calculation.
    /// @param _totalReserve The current reserve state to be used in the calculation.
    /// @param _supply The current supply state to be used in the calculation.
    /// @return _supplyDelta token amount in wei.
    function _calculateReserveToTokens(
      uint256 _reserveDelta,
      uint256 _totalReserve,
      uint256 _supply
    ) internal pure returns (uint256 _supplyDelta) {
      uint256 _reserve = _totalReserve;
      uint256 _newReserve = _reserve.add(_reserveDelta);
      // s = sqrt(2 * r / m)
      uint256 _newSupply = MathUtils.sqrt(
        _newReserve
          .mul(2)
          .mul(DIVIDER) // inverse the operation (Divider instead of multiplier)
          .mul(1e18) // compensation for the squared unit
      );

      _supplyDelta = _newSupply.sub(_supply);
    }

    /// @notice Computes the decrease in reserve given an amount of tokens.
    /// @param _supplyDelta The amount of tokens in wei to be used in the calculation.
    /// @param _supply The current supply state to be used in the calculation.
    /// @param _totalReserve The current reserve state to be used in the calculation.
    /// @return _reserveDelta Reserve amount in wei.
    function _calculateTokensToReserve(
      uint256 _supplyDelta,
      uint256 _supply,
      uint256 _totalReserve
    ) internal pure returns (uint256 _reserveDelta) {
      require(_supplyDelta <= _supply, 'Token amount must be less than the supply');

      uint256 _newSupply = _supply.sub(_supplyDelta);

      uint256 _newReserve = _calculateReserveFromSupply(_newSupply);

      _reserveDelta = _totalReserve.sub(_newReserve);
    }

    /// @notice Calculates reserve given a specific supply.
    /// @param _supply The token supply in wei to be used in the calculation.
    /// @return _reserve Reserve amount in wei.
    function _calculateReserveFromSupply(uint256 _supply) internal pure returns (uint256 _reserve) {
      // r = s^2 * m / 2
      _reserve = _supply
        .mul(_supply)
        .div(DIVIDER) // inverse the operation (Divider instead of multiplier)
        .div(2)
        .roundedDiv(1e18); // correction of the squared unit
    }

    function addSnowBankVault(address _snowBankVault) public onlyOwner {
        snowBankVault[_snowBankVault] = true;
        emit AddSnowBankVault(_snowBankVault);
    }

    function removeSnowBankVault(address _snowBankVault) public onlyOwner {
        snowBankVault[_snowBankVault] = false;
        emit RemoveSnowBankVault(_snowBankVault);
    }
}
