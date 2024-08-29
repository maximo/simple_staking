// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Staking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256[] public lockupPeriods = [7 days, 30 days, 90 days, 150 days];
    uint256[] public multipliers = [110, 150, 200, 250];
    uint256 public constant BASE_APR = 100; // represent in percent
    bool public allowStaking = true;

    address public immutable TOKEN;
    address public immutable rewardAccount;

    uint256 public totalStakedTOKEN;
    mapping(address => bool) public isRewardFrozen; // track if a user's reward is frozen due to malicious attempts

    struct DepositProof {
        uint256 amount;
        uint256 startTime;
        uint256 liability;
        uint256 expiryTime;
    }
    mapping(address => DepositProof[]) balances;

    /// Events
    event Staked(address account, uint256 amount, uint256 totalStakedTOKEN);
    event Withdrawn(address account, uint256 amount, uint256 totalStakedTOKEN);
    event WithdrawnWithPenalty(address account, uint256 amount, uint256 totalStakedTOKEN);
    event RewardFrozen(address account, bool status);
    event StakingEnabled(bool status);

    constructor(address _TOKEN, address _rewardAccount) {
        assert(lockupPeriods.length == multipliers.length);
        require(_TOKEN != address(0), "_TOKEN is zero address");
        require(_rewardAccount != address(0), "_rewardAccount is zero address");
        TOKEN = _TOKEN;
        rewardAccount = _rewardAccount;
    }

    /**
     * @dev get number of deposits for an account
     */
    function getNumDeposits(address account) external view returns (uint256) {
        return balances[account].length;
    }

    /**
     * @dev get N-th deposit for an account
     */
    function getDeposits(address account, uint256 index)
        external
        view
        returns (DepositProof memory)
    {
        return balances[account][index];
    }

    function getLiability(
        uint256 deposit,
        uint256 multiplier,
        uint256 lockupPeriod
    ) public view returns (uint256) {
        // calc liability
        return
            (deposit * BASE_APR * multiplier * lockupPeriod) /
            (1 days) /
            (100 * 100 * 365); // remember to div by 100 // remember to div by 100
    }

    function setRewardFrozen(address account, bool status) external onlyOwner {
        isRewardFrozen[account] = status;
        emit RewardFrozen(account, status);
    }

    /**
     * @dev allow owner to enable and disable staking.
     */
    function toggleStaking() external onlyOwner {
        allowStaking = !allowStaking;
        emit StakingEnabled(allowStaking);
    }

    function stake(uint256 amount, uint256 lockPeriod) external nonReentrant {
        require(amount > 0, "cannot stake 0"); // don't allow staking 0

        // Check is staking is enabled
        require(allowStaking, "staking is disabled");

        address account = _msgSender();
        uint256 multiplier = 0;
        for (uint256 i = 0; i < lockupPeriods.length; i++) {
            if (lockPeriod == lockupPeriods[i]) {
                multiplier = multipliers[i];
                break;
            }
        }
        require(multiplier > 0, "invalid lock period");

        uint256 liability = getLiability(amount, multiplier, lockPeriod);
        require(
            IERC20(TOKEN).balanceOf(rewardAccount) >= liability,
            "insufficient budget"
        );

        DepositProof memory deposit = DepositProof({
            amount: amount,
            expiryTime: block.timestamp + lockPeriod,
            startTime: block.timestamp,
            liability: liability
        });
        balances[account].push(deposit);

        totalStakedTOKEN += deposit.amount;

        // TODO: NEEDS COMMENTS
        IERC20(TOKEN).safeTransferFrom(account, address(this), amount);
        IERC20(TOKEN).safeTransferFrom(rewardAccount, address(this), liability);

        emit Staked(account, amount, totalStakedTOKEN);
    }

    function withdraw(uint256 index) external nonReentrant {
        address account = _msgSender();
        require(index < balances[account].length, "invalid account or index");
        DepositProof memory deposit = balances[account][index];
        require(deposit.expiryTime <= block.timestamp, "not expired");

        // destroy deposit by:
        // replacing index with last one, and pop out the last element
        uint256 last = balances[account].length;
        balances[account][index] = balances[account][last - 1];
        balances[account].pop();

        totalStakedTOKEN -= deposit.amount;

        if (!isRewardFrozen[account]) {
            uint256 withdrawAmount = deposit.liability + deposit.amount;
            IERC20(TOKEN).safeTransfer(account, withdrawAmount);
            emit Withdrawn(account, withdrawAmount, totalStakedTOKEN);
        } else {
            IERC20(TOKEN).safeTransfer(rewardAccount, deposit.liability); // user forfeits reward and reward is sent to reward pool
            IERC20(TOKEN).safeTransfer(account, deposit.amount);
            emit WithdrawnWithPenalty(account, deposit.amount, totalStakedTOKEN);
        }
    }
}
