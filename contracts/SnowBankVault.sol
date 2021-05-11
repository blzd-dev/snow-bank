// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Inheritance
import "./interfaces/IMasterChef.sol";
import "./interfaces/IStakingRewards.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IBank.sol";
import "./interfaces/ISnowBank.sol";

contract SnowBankVault is IStakingRewards, Ownable , ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ============= */

    address private constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    IMasterChef private constant CAKE_MASTER_CHEF = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);

    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address[] public cakeToBnbPath = [CAKE,WBNB];
    address[] public cakeToBusdPath = [CAKE,WBNB,BUSD];

    IPancakeRouter02 public constant ROUTER = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /* ========== STATE VARIABLES ========== */

    IERC20 public stakingToken;

    // Reward ID 0 IBNB 1 GALE
    address public IBNB ;
    address public GALE ;
    address public snowBank;

    mapping(uint256 => uint256) public rewardRate;
    mapping(uint256 => uint256) public rewardPerTokenStored;
    mapping(uint256 => uint256) public rewardsDuration;

    mapping(uint256 => uint256) public lastUpdateTime;
    mapping(uint256 => uint256) public periodFinish;

    uint256 public pid;

    address public distributionBusd;


    mapping(uint256 => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(uint256 => mapping(address => uint256)) public rewards;

    uint256 private _totalSupply;

    mapping (address => bool) public rewardsDistributions;

    mapping(address => uint256) private _balances;

    address public distributionBUSD;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        uint256 _pid,
        address _distributionBUSD,
        address _IBNB,
        address _snowBank
    ) public {
        (address _stakingToken,,,) = CAKE_MASTER_CHEF.poolInfo(_pid);

        pid = _pid;

        IBNB = _IBNB;

        snowBank = _snowBank;

        GALE = ISnowBank(_snowBank).gale();

        stakingToken = IERC20(_stakingToken);

        stakingToken.safeApprove(address(CAKE_MASTER_CHEF), uint256(-1));
        IERC20(CAKE).safeApprove(address(ROUTER), uint256(-1));
        IERC20(BUSD).safeApprove(address(snowBank), uint256(-2));

        distributionBUSD = _distributionBUSD;

        rewardsDuration[0] = 4 hours;
        rewardsDuration[1] = 4 hours;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable(uint256 rewardId) public view override returns (uint256) {
        return Math.min(block.timestamp, periodFinish[rewardId]);
    }

    function rewardPerToken(uint256 rewardId) public view override returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored[rewardId];
        }
        return
            rewardPerTokenStored[rewardId].add(
                lastTimeRewardApplicable(rewardId).sub(lastUpdateTime[rewardId]).mul(rewardRate[rewardId]).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account,uint256 rewardId) public view override returns (uint256) {
        return _balances[account].mul(rewardPerToken(rewardId).sub(userRewardPerTokenPaid[rewardId][account])).div(1e18).add(rewards[rewardId][account]);
    }

    function getRewardForDuration(uint256 rewardId) external view override returns (uint256) {
        return rewardRate[rewardId].mul(rewardsDuration[rewardId]);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender,0) updateReward(msg.sender,1) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        CAKE_MASTER_CHEF.deposit(pid, amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender,0) updateReward(msg.sender,1) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        CAKE_MASTER_CHEF.withdraw(pid, amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward(uint256 rewardId) public override nonReentrant updateReward(msg.sender,rewardId) {
        require(rewardId <= 1 ,"wrong rewardId");
        uint256 reward = rewards[rewardId][msg.sender];
        if (reward > 0) {
            rewards[rewardId][msg.sender] = 0;
            IERC20 rewardsToken = rewardId == 0 ? IERC20(IBNB) : IERC20(GALE);
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward , rewardId);
        }
    }

    function exit() external override {
        withdraw(_balances[msg.sender]);
        getReward(0);
        getReward(1);
    }

    function harvest() public onlyRewardsDistribution {
        CAKE_MASTER_CHEF.withdraw(pid, 0);
        _harvest();
    }

    function notifyRewardAmount(uint256 reward,uint256 rewardId) public onlyRewardsDistribution {
        _notifyRewardAmount(reward,rewardId);
    }


    receive () external payable {}

    /* ========== RESTRICTED FUNCTIONS ========== */


    function _harvest() private {
        uint256 cakeAmount = IERC20(CAKE).balanceOf(address(this));

        uint256 cakeAmontForIBNB = cakeAmount.mul(70).div(100);

        ROUTER.swapExactTokensForETH(cakeAmontForIBNB, 0, cakeToBnbPath, address(this), now + 600);

        uint256 _before = IBank(IBNB).balanceOf(address(this));

        IBank(IBNB).deposit{value:address(this).balance}();

        uint256 amountIBNB = IBank(IBNB).balanceOf(address(this)).sub(_before);
        // ADD IBNB Reward
        if (amountIBNB > 0) {
            _notifyRewardAmount(amountIBNB,0);
        }

        uint256 cakeToBUSD = cakeAmount.sub(cakeAmontForIBNB);

        ROUTER.swapExactTokensForTokens(cakeToBUSD, 0, cakeToBusdPath, address(this), now + 600);

        uint256 amountBusd = IERC20(BUSD).balanceOf(address(this));

        uint256 usdAmountForGale = amountBusd.mul(25).div(30);

        ISnowBank(snowBank).invest(usdAmountForGale);

        uint256 amountGale = IERC20(GALE).balanceOf(address (this));
         if (amountGale > 0) {
            _notifyRewardAmount(amountGale,1);
        }

        // Remaining 5% go to distribution
        IERC20(BUSD).transfer(distributionBUSD, amountBusd.sub(usdAmountForGale));

        emit Harvested(cakeAmount);
    }

    function _notifyRewardAmount(uint256 reward,uint256 rewardId) internal updateReward(address(0),rewardId) {
        require(rewardId <= 1 ,"wrong rewardId");
        if (block.timestamp >= periodFinish[rewardId]) {
            rewardRate[rewardId] = reward.div(rewardsDuration[rewardId]);
        } else {
            uint256 remaining = periodFinish[rewardId].sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate[rewardId]);
            rewardRate[rewardId] = reward.add(leftover).div(rewardsDuration[rewardId]);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        IERC20 rewardsToken = rewardId == 0 ? IERC20(IBNB) : IERC20(GALE);
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(rewardRate[rewardId] <= balance.div(rewardsDuration[rewardId]), "Provided reward too high");

        lastUpdateTime[rewardId] = block.timestamp;
        periodFinish[rewardId] = block.timestamp.add(rewardsDuration[rewardId]);
        emit RewardAdded(reward,rewardId);
    }

    function addRewardsDistribution(address _distributor) public onlyOwner
    {
        rewardsDistributions[_distributor] = true;
    }

    function removeRewardsDistribution(address _distributor) public onlyOwner
    {
        rewardsDistributions[_distributor] = false;
    }

    function setRewardsDuration(uint256 _rewardsDuration,uint256 rewardId) external onlyOwner {
        require(periodFinish[rewardId] == 0 || block.timestamp > periodFinish[rewardId], "Reward duration can only be updated after the period ends");
        rewardsDuration[rewardId] = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration[rewardId],rewardId);
    }


    /* ========== MODIFIERS ========== */

    modifier updateReward(address account,uint256 rewardId) {
        rewardPerTokenStored[rewardId] = rewardPerToken(rewardId);
        lastUpdateTime[rewardId] = lastTimeRewardApplicable(rewardId);
        if (account != address(0)) {
            rewards[rewardId][account] = earned(account,rewardId);
            userRewardPerTokenPaid[rewardId][account] = rewardPerTokenStored[rewardId];
        }
        _;
    }

    modifier onlyRewardsDistribution() {
        require(rewardsDistributions[msg.sender] , "Caller is not RewardsDistribution contract");
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward,uint256 rewardId);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward ,uint256 rewardId);
    event Harvested(uint256 amount);
    event RewardsDurationUpdated(uint256 newDuration,uint256 rewardId);

}
