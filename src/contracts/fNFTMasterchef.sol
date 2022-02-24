// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "@boringcrypto/boring-solidity/contracts/BoringBatchable.sol";
import "@boringcrypto/boring-solidity/contracts/BoringOwnable.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/IRewarder.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IfNFTStakingDistributor.sol";

/// @notice The (older) MasterChef contract gives out a constant number of ART tokens per block.
/// It is the only address with minting rights for ART.
/// The idea for this MasterChef V2 (MCV2) contract is therefore to be the owner of a dummy token
/// that is deposited into the MasterChef V1 (MCV1) contract.
/// The allocation point for this pool on MCV1 is the total allocation point for all pools that receive double incentives.
contract MasterChefV2 is BoringOwnable, BoringBatchable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of ART entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each MCV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of ART to distribute per block.
    struct PoolInfo {
        uint128 accArtPerShare;
        uint64 lastRewardBlock;
        uint64 allocPoint;
    }

    /// @notice Address of ART contract.
    IERC20 public immutable ART;
    IfNFTStakingDistributor public fNFTStakingDistributor;
    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each MCV2 pool.
    IERC20[] public fnft;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 private constant MASTERCHEF_ART_PER_BLOCK = 1e20;
    uint256 private constant ACC_ART_PRECISION = 1e12;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed fnft, IRewarder indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardBlock, uint256 lpSupply, uint256 accArtPerShare);
    event LogInit();

    /// @param _art The ART token contract address.
    constructor(IERC20 _art, IfNFTStakingDistributor _fNFTStakingDistributor) public {
        ART = _art;
        fNFTStakingDistributor = _fNFTStakingDistributor;
    }
    
    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _fnft Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(uint256 _allocPoint, IERC20 _fnft, IRewarder _rewarder) public onlyOwner {        
        uint256 lastRewardBlock = block.number;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        fnft.push(_fnft);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({
            allocPoint: _allocPoint.to64(),
            lastRewardBlock: lastRewardBlock.to64(),
            accArtPerShare: 0
        }));
        emit LogPoolAddition(fnft.length.sub(1), _allocPoint, _fnft, _rewarder);
    }

    /// @notice Update the given pool's ART allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, bool _overwrite) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        if (_overwrite) { rewarder[_pid] = _rewarder; }
        emit LogSetPool(_pid, _allocPoint, _overwrite ? _rewarder : rewarder[_pid], _overwrite);
    }

    /// @notice View function to see pending ART on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending ART reward for a given user.
    function pendingArt(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accArtPerShare = pool.accArtPerShare;
        uint256 lpSupply = fnft[_pid].balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocks = block.number.sub(pool.lastRewardBlock);
            uint256 artReward = blocks.mul(artPerBlock()).mul(pool.allocPoint) / totalAllocPoint;
            accArtPerShare = accArtPerShare.add(artReward.mul(ACC_ART_PRECISION) / lpSupply);
        }
        pending = int256(user.amount.mul(accArtPerShare) / ACC_ART_PRECISION).sub(user.rewardDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata _pids) external {
        uint256 len = _pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(_pids[i]);
        }
    }

    /// @notice Calculates and returns the `amount` of ART per block.
    function artPerBlock() public view returns (uint256 amount) {
        amount = uint256(MASTERCHEF_ART_PER_BLOCK);
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 _pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[_pid];
        if (block.number > pool.lastRewardBlock) {
            uint256 lpSupply = fnft[_pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 blocks = block.number.sub(pool.lastRewardBlock);
                uint256 artReward = blocks.mul(artPerBlock()).mul(pool.allocPoint) / totalAllocPoint;
                pool.accArtPerShare = pool.accArtPerShare.add((artReward.mul(ACC_ART_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardBlock = block.number.to64();
            poolInfo[_pid] = pool;
            emit LogUpdatePool(_pid, pool.lastRewardBlock, lpSupply, pool.accArtPerShare);
        }
    }

    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 _pid, uint256 _amount, address _to, bool _trigger) public {
        if (_trigger) {
            fNFTStakingDistributor.rebase();
        }
        PoolInfo memory pool = updatePool(_pid);
        UserInfo storage user = userInfo[_pid][_to];

        // Effects
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.rewardDebt.add(int256(_amount.mul(pool.accArtPerShare) / ACC_ART_PRECISION));

        // Interactions
        IRewarder _rewarder = rewarder[_pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onArtReward(_pid, _to, _to, 0, user.amount);
        }

        fnft[_pid].safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposit(msg.sender, _pid, _amount, _to);
    }

    /// @notice Withdraw LP tokens from MCV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 _pid, uint256 _amount, address _to, bool _trigger) public {
        if (_trigger) {
            fNFTStakingDistributor.rebase();
        }
        PoolInfo memory pool = updatePool(_pid);
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(_amount.mul(pool.accArtPerShare) / ACC_ART_PRECISION));
        user.amount = user.amount.sub(_amount);

        // Interactions
        IRewarder _rewarder = rewarder[_pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onArtReward(_pid, msg.sender, _to, 0, user.amount);
        }
        
        fnft[_pid].safeTransfer(_to, _amount);

        emit Withdraw(msg.sender, _pid, _amount, _to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of ART rewards.
    function harvest(uint256 _pid, address _to) public {
        PoolInfo memory pool = updatePool(_pid);
        UserInfo storage user = userInfo[_pid][msg.sender];
        int256 accumulatedArt = int256(user.amount.mul(pool.accArtPerShare) / ACC_ART_PRECISION);
        uint256 _pendingArt = accumulatedArt.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedArt;

        // Interactions
        if (_pendingArt != 0) {
            ART.safeTransfer(_to, _pendingArt);
        }
        
        IRewarder _rewarder = rewarder[_pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onArtReward( _pid, msg.sender, _to, _pendingArt, user.amount);
        }

        emit Harvest(msg.sender, _pid, _pendingArt);
    }
    
    /// @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens and ART rewards.
    function withdrawAndHarvest(uint256 _pid, uint256 _amount, address _to) public {
        PoolInfo memory pool = updatePool(_pid);
        UserInfo storage user = userInfo[_pid][msg.sender];
        int256 accumulatedArt = int256(user.amount.mul(pool.accArtPerShare) / ACC_ART_PRECISION);
        uint256 _pendingArt = accumulatedArt.sub(user.rewardDebt).toUInt256();

        // Effects
        user.rewardDebt = accumulatedArt.sub(int256(_amount.mul(pool.accArtPerShare) / ACC_ART_PRECISION));
        user.amount = user.amount.sub(_amount);
        
        // Interactions
        ART.safeTransfer(_to, _pendingArt);

        IRewarder _rewarder = rewarder[_pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onArtReward(_pid, msg.sender, _to, _pendingArt, user.amount);
        }

        fnft[_pid].safeTransfer(_to, _amount);

        emit Withdraw(msg.sender, _pid, _amount, _to);
        emit Harvest(msg.sender, _pid, _pendingArt);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 _pid, address _to) public {
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        IRewarder _rewarder = rewarder[_pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onArtReward(_pid, msg.sender, _to, 0, 0);
        }

        // Note: transfer can fail or succeed if `amount` is zero.
        fnft[_pid].safeTransfer(_to, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount, _to);
    }
}