pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './types/RenaissanceAccessControlled.sol';
import './interfaces/IRenaissanceAuthority.sol';

interface IMigrator {
    // Perform fNFT token migration from legacy fNFTStaking contracts.
    // Take the current fNFT token address and return the new fNFT token address.
    // Migrator should have full access to the caller's fNFT token.
    // Return the new fNFT token address.    
    function migrate(IERC20 token) external returns (IERC20);
}

contract FNFTStaking is RenaissanceAccessControlled {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many fNFT tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of ARTs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accArtPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws fNFT tokens to a pool. Here's what happens:
        //   1. The pool's `accArtPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 fNFTToken;           // Address of fNFT token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. ARTs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that ARTs distribution occurs.
        uint256 accArtPerShare; // Accumulated ARTs per share, times 1e12. See below.
    }

    // The ART TOKEN!
    ArtToken public art;    
    // Address for taxes to the devs.
    address public palette;
    // ART tokens created per block.
    uint256 public artPerBlock;
    // Bonus muliplier for early art makers.
    uint256 public BONUS_MULTIPLIER = 1;
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

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        ArtToken _art,
        address _palette,
        uint256 _artPerBlock,
        uint256 _startBlock,
        address _authority
    ) public RenaissanceAccessControlled(IRenaissanceAuthority(_authority)) {
        art = _art;
        palette = _palette;
        artPerBlock = _artPerBlock;
        startBlock = _startBlock;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyPolicy {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new fNFT to the pool. Can only be called by the owner.
    // XXX DO NOT add the same fNFT token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _fNFTToken, bool _withUpdate) public onlyPolicy {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            fNFTToken: _fNFTToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accArtPerShare: 0
        }));
    }

    // Update the given pool's ART allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyPolicy {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigrator _migrator) public onlyPolicy {
        migrator = _migrator;
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

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending ARTs on frontend.
    function pendingArt(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accArtPerShare = pool.accArtPerShare;
        uint256 fNFTSupply = pool.fNFTToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && fNFTSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 artReward = multiplier.mul(artPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accArtPerShare = accArtPerShare.add(artReward.mul(1e12).div(fNFTSupply));
        }
        return user.amount.mul(accArtPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 fNFTSupply = pool.fNFTToken.balanceOf(address(this));
        if (fNFTSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 artReward = multiplier.mul(artPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        art.mint(palette, artReward.div(10));
        art.mint(address(this), artReward);
        pool.accArtPerShare = pool.accArtPerShare.add(artReward.mul(1e12).div(fNFTSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit fNFT tokens for ART allocation.
    function deposit(uint256 _pid, uint256 _amount) public {

        require (_pid != 0, 'deposit ART by staking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accArtPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeArtTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.fNFTToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accArtPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw fNFT tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {

        require (_pid != 0, 'withdraw ART by unstaking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accArtPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeArtTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.fNFTToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accArtPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.fNFTToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe art transfer function, just in case if rounding error causes pool to not have enough ARTs.
    function safeArtTransfer(address _to, uint256 _amount) internal {
        uint256 artBal = art.balanceOf(address(this));
        if (_amount > artBal) {
            art.transfer(_to, artBal);
        } else {
            art.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _palette) public onlyGovernor {        
        palette = _palette;
    }
}