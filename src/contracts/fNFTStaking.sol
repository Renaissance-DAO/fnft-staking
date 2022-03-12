pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './types/RenaissanceAccessControlled.sol';
import './interfaces/IRenaissanceAuthority.sol';
import './interfaces/ITreasury.sol';

interface IMigrator {
    // Perform fNFT token migration from legacy fNFTStaking contracts.
    // Take the current fNFT token address and return the new fNFT token address.
    // Migrator should have full access to the caller's fNFT token.
    // Return the new fNFT token address.    
    function migrate(IERC20 token) external returns (IERC20);
}

interface IMigrator {      
    function migrate(IERC20 token) external returns (IERC20);
}

contract FNFTStaking is RenaissanceAccessControlled { 
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 lastRewardedBlock;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 fNFTToken;           // Address of fNFT token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. ARTs to distribute per block.
        uint256 amountStaked;
    }

    // The treasury for minting ART.
    ITreasury public treasury;
    // The sART token.
    IERC20 public sART;
    // ART tokens created per block.
    uint256 public artPerBlock;
    // sART tokens that need to be staked per fNFT staked.
    uint256 public requiredSArtPerShare;
    // Bonus muliplier for early art makers.
    uint256 public bonusMultiplier = 1;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigrator public migrator;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes fNFT tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when ART mining starts.
    uint256 public startBlock;

    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);    
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        ITreasury _treasury,
        IERC20 _sART,
        uint256 _requiredSArtPerShare,
        uint256 _artPerBlock,
        uint256 _startBlock,
        address _authority
    ) public RenaissanceAccessControlled(IRenaissanceAuthority(_authority)) {
        treasury = _treasury;
        sART = _sART;
        requiredSArtPerShare = _requiredSArtPerShare;
        artPerBlock = _artPerBlock;
        startBlock = _startBlock;
    }
    
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, IERC20 _fNFTToken) public onlyPolicy {
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolInfo.push(PoolInfo({
            fNFTToken: _fNFTToken,
            allocPoint: _allocPoint,
            amountStaked: 0
        }));
    }

    // Update the given pool's ART allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyPolicy {        
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint - prevAllocPoint + _allocPoint);
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return (_to - _from) * bonusMultiplier;
    }

    // View function to see pending ARTs on frontend.
    function pendingArt(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo pool = poolInfo[_pid];
        UserInfo user = userInfo[_pid][_user];
        uint256 fNFTSupply = pool.fNFTToken.balanceOf(address(this));
        if (block.number > user.lastRewardBlock && fNFTSupply != 0) {
            uint256 multiplier = getMultiplier(user.lastRewardedBlock, block.number);
            uint256 poolArtReward = multiplier * artPerBlock * pool.allocPoint / totalAllocPoint;

            return user.amount * poolArtReward / pool.amountStaked;
        } else {
            return 0;
        }        
    }

    // Deposit fNFT tokens for ART allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount > 0) {
            uint256 pending = pendingArt(_pid, msg.sender);
            if(pending > 0) {
                safeArtTransfer(msg.sender, pending);
                emit Harvest(msg.sender, _pid, pending);
            }
        }
        if (_amount > 0) {
            pool.fNFTToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount += _amount;
        }
        user.lastRewardedBlock = block.number;
        pool.amountStaked += _amount;
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw fNFT tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: over lim");
        
        if (user.amount > 0) {
            uint256 pending = pendingArt(_pid, msg.sender);
            if(pending > 0) {
                safeArtTransfer(msg.sender, pending);
                emit Harvest(msg.sender, _pid, pending);
            }
        }
        if(_amount > 0) {
            user.amount -= _amount;
            pool.fNFTToken.safeTransfer(address(msg.sender), _amount);
        }
        user.lastRewardedBlock = block.number;
        pool.amountStaked -= _amount;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.fNFTToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.lastRewardedBlock = block.number;
    }

    /// @notice Harvest proceeds for transaction sender to `to`.    
    function harvest(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];        
        if (user.amount > 0) {
            uint256 pending = pendingArt(_pid, msg.sender);
            if(pending > 0) {
                safeArtTransfer(msg.sender, pending);
                emit Harvest(msg.sender, _pid, pending);
            }
        }        
        user.lastRewardedBlock = block.number;        
    }
    
    function safeArtTransfer(address _to, uint256 _amount) internal {
        treasury.mintRewards(_to, _amount);        
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigrator _migrator) public onlyGovernor {
        migrator = _migrator;
    }    

    function updateArtPerBlock(uint256 _artPerBlock) public onlyPolicy {
        artPerBlock = _artPerBlock;
    }

    function updateMultiplier(uint256 _bonusMultiplier) public onlyPolicy {
        bonusMultiplier = _bonusMultiplier;
    }

    // Migrate fNFT token to another fNFT contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 fNFTToken = pool.fNFTToken;
        uint256 bal = fNFTToken.balanceOf(address(this));
        fNFTToken.safeApprove(address(migrator), bal);
        IERC20 newFNFTToken = migrator.migrate(fNFTToken);
        require(bal == newFNFTToken.balanceOf(address(this)), "migrate: bad");
        pool.fNFTToken = newFNFTToken;
    }
}