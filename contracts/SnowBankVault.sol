// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './StakeBlzdToken.sol';
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
import "./interfaces/IYetiMaster.sol";

contract SnowBankVault is IStakingRewards, Ownable , ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ============= */

    // team 1.5%
    // each 0.75%
    address private constant teamYetiA = 0xCe059E8af96a654d4afe630Fa325FBF70043Ab11;
    address private constant teamYetiB = 0x1EE101AC64BcE7F6DD85C0Ad300C4BBC2cc8272B;

    // 3% BUSD 
    address private constant blizzardPool = 0x2Dcf7FB5F83594bBD13C781f5b8b2a9F55a4cdbb;

    address private constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    IMasterChef private constant CAKE_MASTER_CHEF = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);

    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address[] public cakeToBnbPath = [CAKE,WBNB];
    address[] public cakeToBusdPath = [CAKE,WBNB,BUSD];

    IPancakeRouter02 public constant ROUTER = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable stakingToken;

    // Reward ID 0 IBNB 1 GALE 3 xBLZD
    address public immutable IBNB ;
    address public immutable GALE ;
    address public immutable snowBank;
    StakeBlzdToken public immutable stakeBlzdToken;
    address public immutable xBLZD;
    IYetiMaster public immutable yetiMaster;

    mapping(uint256 => uint256) public rewardRate;
    mapping(uint256 => uint256) public rewardPerTokenStored;
    mapping(uint256 => uint256) public rewardsDuration;

    mapping(uint256 => uint256) public lastUpdateTime;
    mapping(uint256 => uint256) public periodFinish;

    uint256 public pid;
    uint256 public pidYeti;
    bool public initYeti;

    mapping(uint256 => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(uint256 => mapping(address => uint256)) public rewards;

    uint256 private _totalSupply;

    mapping (address => bool) public rewardsDistributions;

    mapping(address => uint256) private _balances;

    bool public emergencyStop;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        uint256 _pid,
        address _IBNB,
        address _snowBank,
        address _yetiMaster
    ) public {
        (address _stakingToken,,,) = CAKE_MASTER_CHEF.poolInfo(_pid);

        pid = _pid;

        IBNB = _IBNB;

        snowBank = _snowBank;

        GALE = ISnowBank(_snowBank).gale();

        xBLZD = IYetiMaster(_yetiMaster).xBLZD();

        yetiMaster = IYetiMaster(_yetiMaster);

        stakeBlzdToken = new StakeBlzdToken(address(this));

        IERC20(_stakingToken).safeApprove(address(CAKE_MASTER_CHEF), uint256(-1));
        
        stakingToken = IERC20(_stakingToken);

        IERC20(CAKE).safeApprove(address(ROUTER), uint256(-1));
        IERC20(BUSD).safeApprove(address(_snowBank), uint256(-1));

        rewardsDuration[0] = 4 hours;
        rewardsDuration[1] = 4 hours;
        rewardsDuration[2] = 4 hours;
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
    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender,0) updateReward(msg.sender,1) updateReward(msg.sender,2) isNotEmergencyStop{
        require(amount > 0, "Cannot stake 0");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
         // fee 0.1% go to blizzardPool
        uint256 depositFee = amount.div(10000);
        stakingToken.safeTransfer(blizzardPool, depositFee);
        uint256 amounAfterFee =  amount.sub(depositFee);
        _totalSupply = _totalSupply.add(amounAfterFee);
        _balances[msg.sender] = _balances[msg.sender].add(amounAfterFee);
        CAKE_MASTER_CHEF.deposit(pid, amounAfterFee);        
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender,0) updateReward(msg.sender,1) updateReward(msg.sender,2) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        if(emergencyStop != true){
            CAKE_MASTER_CHEF.withdraw(pid, amount);
        } 
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward(uint256 rewardId) public override nonReentrant updateReward(msg.sender,rewardId) {
        require(rewardId <= 2 ,"wrong rewardId");
        uint256 reward = rewards[rewardId][msg.sender];
        if (reward > 0) {
            rewards[rewardId][msg.sender] = 0;
            IERC20 rewardsToken;
            if(rewardId  == 0){
                rewardsToken = IERC20(IBNB);
            } 
            else if (rewardId == 1){
                rewardsToken = IERC20(GALE);
            }
            else{
                rewardsToken = IERC20(xBLZD);
            }
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward , rewardId);
        }
    }

    function exit(uint256 amount) external override {
        withdraw(amount);
        getAllReward();
    }

    function getAllReward() public override {
        getReward(0);
        getReward(1);
        getReward(2);
    }
    
    function initYetiPool(uint256 _pidYeti) public onlyOwner{
        require(!initYeti,"Already Initiated");
        IERC20(address(stakeBlzdToken)).safeApprove(address(yetiMaster), uint256(-1));
        pidYeti = _pidYeti;
        initYeti = true;
        yetiMaster.deposit(pidYeti, 100e18);
    }

    function harvest() public onlyRewardsDistribution isNotEmergencyStop {
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

        // 47.5% go to IBNB
        uint256 cakeAmountForIBNB = cakeAmount.mul(475).div(1000);

        ROUTER.swapExactTokensForETH(cakeAmountForIBNB, 0, cakeToBnbPath, address(this), now + 600);

        uint256 iBNBBefore = IBank(IBNB).balanceOf(address(this));

        IBank(IBNB).deposit{value:address(this).balance}();

        uint256 amountIBNB = IBank(IBNB).balanceOf(address(this)).sub(iBNBBefore);
        // ADD IBNB Reward
        if (amountIBNB > 0) {
            _notifyRewardAmount(amountIBNB,0);
        }

        // 52.5 swap to BUSD
        uint256 cakeToBUSD = cakeAmount.sub(cakeAmountForIBNB);

        ROUTER.swapExactTokensForTokens(cakeToBUSD, 0, cakeToBusdPath, address(this), now + 600);

        uint256 amountBusd = IERC20(BUSD).balanceOf(address(this));

        // 47.5 in 52.5 go to gale
        uint256 usdAmountForGale = amountBusd.mul(4750000).div(5250000);

        uint256 GaleBefore = IERC20(GALE).balanceOf(address(this));

        ISnowBank(snowBank).invest(usdAmountForGale);

        uint256 amountGale = IERC20(GALE).balanceOf(address(this)).sub(GaleBefore);

        if (amountGale > 0) {
            _notifyRewardAmount(amountGale,1);
        }

        // 3 in 52.5 go to blzdpool
        uint256 usdBlizzardPool = amountBusd.mul(300000).div(5250000);

        IERC20(BUSD).transfer(blizzardPool, usdBlizzardPool);

         // 1.5 in 52.5 go to team
        uint256 usdTeamYeti = amountBusd.mul(150000).div(5250000);

        uint256 usdTeamYetiHalf = usdTeamYeti.div(2);

        IERC20(BUSD).transfer(teamYetiA, usdTeamYetiHalf);

        IERC20(BUSD).transfer(teamYetiB, usdTeamYeti.sub(usdTeamYetiHalf));

        // remaining go to bot 0.5%
        IERC20(BUSD).transfer(msg.sender,
            amountBusd.sub(usdAmountForGale)
            .sub(usdBlizzardPool)
            .sub(usdTeamYeti)
        );

        // harvest xblzd 
        uint256 xBlzdBefore = IERC20(xBLZD).balanceOf(address(this));

        yetiMaster.deposit(pidYeti, 0);

        uint256 amountxBlzd = IERC20(xBLZD).balanceOf(address(this)).sub(xBlzdBefore);

        if (amountxBlzd > 0) {
            _notifyRewardAmount(amountxBlzd,2);
        }

        emit Harvested(cakeAmount);
    }

    function _notifyRewardAmount(uint256 reward,uint256 rewardId) internal updateReward(address(0),rewardId) {
        require(rewardId <= 2 ,"wrong reward id");
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
        emit AddRewardsDistribution(_distributor);
    }

    function removeRewardsDistribution(address _distributor) public onlyOwner
    {
        rewardsDistributions[_distributor] = false;
        emit RemoveRewardsDistribution(_distributor);
    }

    function setRewardsDuration(uint256 _rewardsDuration,uint256 rewardId) external onlyOwner {
        require(periodFinish[rewardId] == 0 || block.timestamp > periodFinish[rewardId], "Reward duration can only be updated after the period ends");
        rewardsDuration[rewardId] = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration[rewardId],rewardId);
    }

    function panic() public onlyOwner {
        emergencyStop = true;
        CAKE_MASTER_CHEF.emergencyWithdraw(pid);
        emit EmergencyWithdrawLp(emergencyStop);
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

    modifier isNotEmergencyStop() {
        require(!emergencyStop , "Emergency Stop");
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward,uint256 rewardId);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward ,uint256 rewardId);
    event Harvested(uint256 amount);
    event RewardsDurationUpdated(uint256 newDuration,uint256 rewardId);
    event AddRewardsDistribution(address indexed distributor);
    event RemoveRewardsDistribution(address indexed distributor);
    event EmergencyWithdrawLp(bool _emergencyStop);

}
