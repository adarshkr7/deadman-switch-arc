// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DeadMansSwitchVault
 * @notice Independent USDC dead-man's switch vaults with fixed beneficiaries and shares.
 * @dev Pass Arc's six-decimal USDC predeploy,
 * 0x3600000000000000000000000000000000000000, to the constructor on Arc.
 * All amounts are token base units. There are no administrators or upgrade hooks.
 * A guardian quorum can delay the deadline before expiry by at most one extension per check-in period.
 * Rotation requires a guardian quorum proposal, the timelock and explicit approval of the exact
 * newOwner by the owner or checkInDelegate; routine check-ins never approve rotations.
 * Beneficiaries, the delegate and the owner can veto any pending rotation at any time.
 * A lost-key owner recovers by having the delegate approve the proposed replacement.
 * A delegate can only check in, approve or veto rotations and must not be a current guardian.
 * An owner who missed the deadline can still rescue the vault by checking in during the
 * challenge window after someone triggers; guardians cannot extend after expiry.
 * Guardians cannot directly transfer vault funds.
 * Deposits never reset the timer and are blocked once claims open, even before
 * finalization. Direct token transfers are not credited and cannot be recovered.
 * The token is trusted to have USDC's non-rebasing transfer semantics; inbound
 * balance-delta accounting additionally avoids overcrediting taxed deposits.
 * Beneficiaries, shares, guardians, fallback identity and delays cannot be reconfigured.
 * The fallback identity can redirect its sweep destination.
 * Unclaimed funds remain claimable from challenge end until the vault is swept.
 */
contract DeadMansSwitchVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint64 public constant MIN_INTERVAL = 60;
    uint64 public constant MAX_INTERVAL = 100 * 365 days;
    uint256 public constant MAX_BENEFICIARIES = 20;
    uint256 public constant MAX_GUARDIANS = 10;
    uint64 public constant MIN_DELAY = 60 seconds;
    uint64 public constant MAX_DELAY = 365 days;
    uint64 public constant MAX_SWEEP_PERIOD = 3650 days;
    uint64 public constant DEFAULT_WITHDRAW_DELAY = 24 hours;
    uint64 public constant DEFAULT_CHALLENGE_WINDOW = 24 hours;
    uint64 public constant DEFAULT_ROTATION_TIMELOCK = 48 hours;
    uint64 public constant DEFAULT_SWEEP_PERIOD = 180 days;

    /// @notice Action tags used in keccak256(abi.encode(tag, params..., guardianNonce)).
    bytes32 public constant EXTEND_DEADLINE_ACTION = keccak256("EXTEND_DEADLINE");
    bytes32 public constant CANCEL_WITHDRAW_ACTION = keccak256("CANCEL_WITHDRAW");
    bytes32 public constant OWNER_ROTATION_ACTION = keccak256("OWNER_ROTATION");

    IERC20 public immutable usdc;
    uint256 public nextVaultId = 1;
    /// @notice Aggregate actual credited deposits, excluding direct token transfers.
    uint256 public totalDeposited;
    /// @notice Aggregate withdrawals, beneficiary claims and fallback sweeps.
    uint256 public totalPaidOut;

    enum Phase { Active, Expired, Challenge, ClaimsOpen, Swept }

    /// @notice Creation parameters; zero delay values select their defaults.
    struct CreateParams {
        address[] beneficiaries;
        uint16[] sharesBps;
        uint64 interval;
        address[] guardians;
        uint8 guardianThreshold;
        uint64 withdrawDelay;
        uint64 challengeWindow;
        uint64 rotationTimelock;
        uint64 sweepPeriod;
        address fallbackAddress;
    }

    /// @notice Immutable per-vault configuration returned by getConfig.
    struct ConfigView {
        uint64 withdrawDelay;
        uint64 challengeWindow;
        uint64 rotationTimelock;
        uint64 sweepPeriod;
        address fallbackAddress;
        uint8 guardianThreshold;
        uint256 guardianCount;
    }

    /// @notice Delayed withdrawal; its amount remains in vault.balance until execution.
    struct PendingWithdrawal {
        uint256 amount;
        uint64 executableAt;
        bool exists;
    }

    /// @notice Quorum-proposed ownership change requiring its timelock and explicit owner/delegate approval.
    struct PendingRotation {
        address newOwner;
        uint64 executableAt;
        bool exists;
        uint64 proposedAt;
        bool approved;
    }

    /// @dev Owner zero denotes a nonexistent vault. Configuration is immutable after creation.
    struct Vault {
        address owner;
        uint64 lastCheckIn;
        uint64 interval;
        uint64 deadline;
        uint256 balance;
        uint256 claimPool;
        uint256 totalClaimed;
        uint256 claimedCount;
        bool triggered;
        uint64 triggeredAt;
        uint64 challengeEnd;
        uint64 sweepAt;
        bool finalized;
        bool swept;
        address checkInDelegate;
        uint256 guardianNonce;
        bool extensionUsed;
        ConfigView config;
        PendingWithdrawal withdrawal;
        PendingRotation rotation;
        address fallbackPayout;
    }

    /// @notice Complete timing and accounting snapshot; phase uses the current timestamp.
    struct VaultView {
        address owner;
        uint64 lastCheckIn;
        uint64 interval;
        uint64 deadline;
        uint256 balance;
        uint256 claimPool;
        uint256 totalClaimed;
        uint256 claimedCount;
        bool triggered;
        uint64 triggeredAt;
        uint64 challengeEnd;
        uint64 sweepAt;
        bool finalized;
        bool swept;
        address checkInDelegate;
        uint256 guardianNonce;
        bool extensionUsed;
        uint256 beneficiaryCount;
        Phase phase;
    }

    mapping(uint256 => Vault) private _vaults;
    mapping(uint256 => address[]) private _beneficiaries;
    mapping(uint256 => mapping(address => uint16)) private _sharesBps;
    mapping(uint256 => mapping(address => bool)) private _claimed;
    mapping(uint256 => mapping(address => address)) private _payoutAddresses;
    mapping(uint256 => address[]) private _guardians;
    mapping(uint256 => mapping(address => bool)) private _isGuardian;
    mapping(uint256 => mapping(bytes32 => uint256)) private _approvalCounts;
    mapping(uint256 => mapping(bytes32 => mapping(address => bool))) private _approved;

    error ZeroTokenAddress();
    error VaultNotFound(uint256 vaultId);
    error EmptyBeneficiaries();
    error LengthMismatch();
    error TooManyBeneficiaries();
    error ZeroBeneficiary();
    error DuplicateBeneficiary(address beneficiary);
    error ZeroShare(address beneficiary);
    error InvalidSharesTotal(uint256 total);
    error InvalidInterval(uint64 interval);
    error TimestampOverflow();
    error NotVaultOwner(uint256 vaultId);
    error VaultExpired(uint256 vaultId);
    error VaultNotExpired(uint256 vaultId);
    error VaultAlreadyTriggered(uint256 vaultId);
    error VaultNotTriggered(uint256 vaultId);
    error ZeroAmount();
    error NoTokensReceived();
    error InsufficientVaultBalance(uint256 available, uint256 requested);
    error NotBeneficiary(uint256 vaultId, address account);
    error AlreadyClaimed(uint256 vaultId, address account);
    error TooManyGuardians();
    error ZeroGuardian();
    error DuplicateGuardian(address guardian);
    error GuardianIsOwner();
    error InvalidGuardianThreshold(uint8 threshold);
    error InvalidDelay(uint64 delay);
    error InvalidFallbackAddress();
    error DepositsClosed(uint256 vaultId);
    error NotOwnerOrDelegate(uint256 vaultId);
    error ChallengeEnded(uint256 vaultId);
    error InvalidDelegate();
    error WithdrawalPending(uint256 vaultId);
    error NoPendingWithdrawal(uint256 vaultId);
    error WithdrawalNotReady(uint256 vaultId);
    error NotOwnerOrGuardian(uint256 vaultId);
    error NotGuardian(uint256 vaultId);
    error AlreadyApproved(uint256 vaultId, bytes32 actionId, address guardian);
    error ExtensionTooLarge(uint256 vaultId);
    error ExtensionAlreadyUsed(uint256 vaultId);
    error DeadlinePassed(uint256 vaultId);
    error InvalidNewOwner();
    error RotationPending(uint256 vaultId);
    error NoPendingRotation(uint256 vaultId);
    error RotationNotReady(uint256 vaultId);
    error RotationTargetMismatch(uint256 vaultId);
    error RotationAlreadyApproved(uint256 vaultId);
    error RotationNotApproved(uint256 vaultId);
    error NotOwnerDelegateOrBeneficiary(uint256 vaultId);
    error ChallengeNotOver(uint256 vaultId);
    error NotTriggered(uint256 vaultId);
    error AlreadyFinalized(uint256 vaultId);
    error InvalidPayoutAddress();
    error VaultSwept(uint256 vaultId);
    error NotFallback(uint256 vaultId);
    error SweepNotReady(uint256 vaultId);
    error AlreadySwept(uint256 vaultId);

    /// @notice Full creation configuration; params contains resolved (nonzero) delays.
    /// @dev A tuple avoids stack pressure when logging the full configuration without via-IR.
    event VaultCreated(uint256 indexed vaultId, address indexed owner, CreateParams params);
    event Deposited(uint256 indexed vaultId, address indexed from, uint256 amount);
    event CheckedIn(uint256 indexed vaultId, address indexed by, uint256 newDeadline);
    event CheckInDelegateSet(uint256 indexed vaultId, address delegate);
    event WithdrawRequested(uint256 indexed vaultId, uint256 amount, uint256 executableAt);
    event WithdrawExecuted(uint256 indexed vaultId, uint256 amount);
    event WithdrawCancelled(uint256 indexed vaultId, address indexed by);
    event GuardianApproved(
        uint256 indexed vaultId, address indexed guardian, bytes32 indexed actionId,
        uint256 approvals, uint8 threshold
    );
    event DeadlineExtended(uint256 indexed vaultId, uint256 newDeadline);
    event ExtensionAllowanceReset(uint256 indexed vaultId, address indexed by);
    event OwnerRotationProposed(uint256 indexed vaultId, address indexed newOwner, uint256 executableAt);
    event OwnerRotationApproved(uint256 indexed vaultId, address indexed newOwner, address indexed by);
    event OwnerRotationCancelled(uint256 indexed vaultId, address indexed by);
    event OwnerRotated(uint256 indexed vaultId, address indexed oldOwner, address indexed newOwner);
    event Triggered(uint256 indexed vaultId, address indexed caller, uint256 challengeEnd, uint256 sweepAt);
    event TriggerCancelled(uint256 indexed vaultId, address indexed by);
    event Finalized(uint256 indexed vaultId, uint256 claimPool);
    event PayoutAddressSet(uint256 indexed vaultId, address indexed beneficiary, address payout);
    event Claimed(uint256 indexed vaultId, address indexed beneficiary, address indexed payoutTo, uint256 amount);
    event FallbackPayoutSet(uint256 indexed vaultId, address payout);
    event Swept(uint256 indexed vaultId, address indexed caller, address indexed fallbackAddress, uint256 amount);

    /// @notice Configure the immutable token; deployment on Arc must pass its USDC predeploy.
    /// @param usdc_ USDC ERC-20 address, or a mock token for testing.
    constructor(IERC20 usdc_) {
        if (address(usdc_) == address(0)) revert ZeroTokenAddress();
        usdc = usdc_;
    }

    /// @notice Create an empty vault with permanent distribution and guardian configuration.
    /// @param p Creation parameters; each zero delay selects its documented default.
    /// @return vaultId Newly assigned identifier, starting at one.
    function createVault(CreateParams calldata p) external nonReentrant returns (uint256 vaultId) {
        if (p.interval < MIN_INTERVAL || p.interval > MAX_INTERVAL) revert InvalidInterval(p.interval);
        uint64 timestamp = _checkedTimestamp(p.interval);
        if (p.fallbackAddress == address(0) || p.fallbackAddress == address(this)
            || p.fallbackAddress == address(usdc)) {
            revert InvalidFallbackAddress();
        }
        vaultId = nextVaultId++;
        _storeBeneficiaries(vaultId, p);
        _storeGuardians(vaultId, p);
        Vault storage vault = _vaults[vaultId];
        vault.owner = msg.sender;
        vault.lastCheckIn = timestamp;
        vault.interval = p.interval;
        vault.deadline = timestamp + p.interval;
        vault.config.withdrawDelay = _resolveDelay(p.withdrawDelay, DEFAULT_WITHDRAW_DELAY, MAX_DELAY);
        vault.config.challengeWindow = _resolveDelay(p.challengeWindow, DEFAULT_CHALLENGE_WINDOW, MAX_DELAY);
        vault.config.rotationTimelock = _resolveDelay(p.rotationTimelock, DEFAULT_ROTATION_TIMELOCK, MAX_DELAY);
        vault.config.sweepPeriod = _resolveDelay(p.sweepPeriod, DEFAULT_SWEEP_PERIOD, MAX_SWEEP_PERIOD);
        vault.config.fallbackAddress = p.fallbackAddress;
        vault.config.guardianThreshold = p.guardianThreshold;
        vault.config.guardianCount = p.guardians.length;
        _emitVaultCreated(vaultId, p, vault.config);
    }

    /// @notice Deposit in Active, Expired or Challenge without resetting any timer.
    /// @dev Requires token approval. Crediting necessarily follows the transfer to
    /// measure its actual balance delta; nonReentrant excludes intervening mutations.
    function deposit(uint256 vaultId, uint256 amount) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (amount == 0) revert ZeroAmount();
        if (vault.swept || (vault.triggered && block.timestamp >= vault.challengeEnd)) {
            revert DepositsClosed(vaultId);
        }
        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = usdc.balanceOf(address(this));
        if (afterBalance <= beforeBalance) revert NoTokensReceived();
        uint256 received = afterBalance - beforeBalance;
        vault.balance += received;
        totalDeposited += received;
        emit Deposited(vaultId, msg.sender, received);
    }

    /// @notice Reset an active timer or cancel a trigger strictly before challenge end.
    /// @dev After missing the deadline, the owner or delegate can rescue only after someone triggers.
    /// Routine check-ins never approve an owner rotation.
    function checkIn(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (msg.sender != vault.owner && msg.sender != vault.checkInDelegate) revert NotOwnerOrDelegate(vaultId);
        if (vault.triggered) {
            if (block.timestamp >= vault.challengeEnd) revert ChallengeEnded(vaultId);
            vault.triggered = false;
            vault.triggeredAt = 0;
            vault.challengeEnd = 0;
            vault.sweepAt = 0;
            emit TriggerCancelled(vaultId, msg.sender);
        } else if (block.timestamp >= vault.deadline) {
            revert VaultExpired(vaultId);
        }
        vault.lastCheckIn = _checkedTimestamp(vault.interval);
        vault.deadline = vault.lastCheckIn + vault.interval;
        if (vault.extensionUsed) {
            vault.extensionUsed = false;
            emit ExtensionAllowanceReset(vaultId, msg.sender);
        }
        emit CheckedIn(vaultId, msg.sender, vault.deadline);
    }

    /// @notice Owner-only delegation of check-in; zero revokes delegation.
    /// @dev Current guardians cannot be delegates, preventing them from explicitly approving rotations.
    function setCheckInDelegate(uint256 vaultId, address delegate) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        _requireOwner(vaultId, vault);
        if (delegate == vault.owner || delegate == address(this) || _isGuardian[vaultId][delegate]) {
            revert InvalidDelegate();
        }
        vault.checkInDelegate = delegate;
        emit CheckInDelegateSet(vaultId, delegate);
    }

    /// @notice Queue one delayed withdrawal; funds stay credited until execution.
    function requestWithdraw(uint256 vaultId, uint256 amount) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        _requireOwner(vaultId, vault);
        _requireActive(vaultId, vault);
        if (amount == 0) revert ZeroAmount();
        if (amount > vault.balance) revert InsufficientVaultBalance(vault.balance, amount);
        if (vault.withdrawal.exists) revert WithdrawalPending(vaultId);
        uint64 executableAt = _futureTimestamp(vault.config.withdrawDelay);
        vault.withdrawal = PendingWithdrawal(amount, executableAt, true);
        emit WithdrawRequested(vaultId, amount, executableAt);
    }

    /// @notice Execute a ready request only while still Active, paying the current owner.
    function executeWithdraw(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        _requireOwner(vaultId, vault);
        PendingWithdrawal memory pending = vault.withdrawal;
        if (!pending.exists) revert NoPendingWithdrawal(vaultId);
        if (block.timestamp < pending.executableAt) revert WithdrawalNotReady(vaultId);
        _requireActive(vaultId, vault);
        if (pending.amount > vault.balance) revert InsufficientVaultBalance(vault.balance, pending.amount);
        delete vault.withdrawal;
        vault.guardianNonce += 1;
        vault.balance -= pending.amount;
        totalPaidOut += pending.amount;
        emit WithdrawExecuted(vaultId, pending.amount);
        usdc.safeTransfer(vault.owner, pending.amount);
    }

    /// @notice Owner cancels immediately; otherwise a guardian quorum must approve.
    /// @dev Cancellation action params are (amount, executableAt); valid in any phase.
    function cancelWithdraw(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        bool ownerCall = msg.sender == vault.owner;
        if (!ownerCall && !_isGuardian[vaultId][msg.sender]) revert NotOwnerOrGuardian(vaultId);
        if (!vault.withdrawal.exists) revert NoPendingWithdrawal(vaultId);
        if (!ownerCall) {
            bytes32 actionId = keccak256(abi.encode(
                CANCEL_WITHDRAW_ACTION, vault.withdrawal.amount, vault.withdrawal.executableAt, vault.guardianNonce
            ));
            if (!_approve(vaultId, vault, actionId)) return;
        } else {
            vault.guardianNonce += 1;
        }
        _clearWithdrawal(vaultId, vault);
    }

    /// @notice Guardian quorum can extend an untriggered deadline only before expiry, once per check-in period.
    /// @dev Action params are (newDeadline). Does not update lastCheckIn; only checkIn resets the allowance.
    /// After expiry, the owner or delegate can rescue by checking in during the challenge window after trigger.
    function extendDeadline(uint256 vaultId, uint64 newDeadline) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        _requireGuardian(vaultId);
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (block.timestamp >= vault.deadline) revert DeadlinePassed(vaultId);
        if (vault.extensionUsed) revert ExtensionAlreadyUsed(vaultId);
        if (newDeadline <= vault.deadline || newDeadline <= block.timestamp
            || uint256(newDeadline) > block.timestamp + uint256(vault.interval)) {
            revert ExtensionTooLarge(vaultId);
        }
        bytes32 actionId = keccak256(abi.encode(EXTEND_DEADLINE_ACTION, newDeadline, vault.guardianNonce));
        if (!_approve(vaultId, vault, actionId)) return;
        vault.deadline = newDeadline;
        vault.extensionUsed = true;
        emit DeadlineExtended(vaultId, newDeadline);
    }

    /// @notice Guardian quorum may queue a replacement requiring a timelock and explicit owner/delegate approval.
    /// @dev Action params are (newOwner); no funds are moved. proposedAt is informational and recorded only at quorum.
    /// The owner, delegate or any beneficiary can veto at any time; routine check-ins never approve.
    function proposeOwnerRotation(uint256 vaultId, address newOwner) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        _requireGuardian(vaultId);
        if (newOwner == address(0) || newOwner == vault.owner || newOwner == address(this)
            || _isGuardian[vaultId][newOwner] || _sharesBps[vaultId][newOwner] != 0
            || newOwner == vault.checkInDelegate || newOwner == vault.config.fallbackAddress) {
            revert InvalidNewOwner();
        }
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (vault.rotation.exists) revert RotationPending(vaultId);
        bytes32 actionId = keccak256(abi.encode(OWNER_ROTATION_ACTION, newOwner, vault.guardianNonce));
        if (!_approve(vaultId, vault, actionId)) return;
        uint64 executableAt = _futureTimestamp(vault.config.rotationTimelock);
        vault.rotation = PendingRotation(newOwner, executableAt, true, uint64(block.timestamp), false);
        emit OwnerRotationProposed(vaultId, newOwner, executableAt);
    }

    /// @notice Current owner or delegate explicitly approves the exact proposed replacement while untriggered.
    /// @dev Approval is allowed before or after the timelock; a lost-key owner can recover through the delegate.
    function approveOwnerRotation(uint256 vaultId, address newOwner) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (msg.sender != vault.owner && msg.sender != vault.checkInDelegate) revert NotOwnerOrDelegate(vaultId);
        PendingRotation storage pending = vault.rotation;
        if (!pending.exists) revert NoPendingRotation(vaultId);
        if (newOwner != pending.newOwner) revert RotationTargetMismatch(vaultId);
        if (pending.approved) revert RotationAlreadyApproved(vaultId);
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        pending.approved = true;
        emit OwnerRotationApproved(vaultId, newOwner, msg.sender);
    }

    /// @notice Anyone may execute a ready, untriggered rotation explicitly approved by the owner or delegate.
    /// @dev Revokes delegation, cancels withdrawals and invalidates outstanding votes; preserves extensionUsed.
    function executeOwnerRotation(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        PendingRotation memory pending = vault.rotation;
        if (!pending.exists) revert NoPendingRotation(vaultId);
        if (block.timestamp < pending.executableAt) revert RotationNotReady(vaultId);
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (!pending.approved) revert RotationNotApproved(vaultId);
        if (pending.newOwner == vault.checkInDelegate) revert InvalidNewOwner();
        address oldOwner = vault.owner;
        vault.owner = pending.newOwner;
        delete vault.rotation;
        if (vault.checkInDelegate != address(0)) {
            vault.checkInDelegate = address(0);
            emit CheckInDelegateSet(vaultId, address(0));
        }
        _clearWithdrawal(vaultId, vault);
        vault.guardianNonce += 1;
        emit OwnerRotated(vaultId, oldOwner, pending.newOwner);
    }

    /// @notice Current owner, delegate or any beneficiary may veto before or after the timelock.
    function cancelOwnerRotation(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (msg.sender != vault.owner && msg.sender != vault.checkInDelegate
            && _sharesBps[vaultId][msg.sender] == 0) {
            revert NotOwnerDelegateOrBeneficiary(vaultId);
        }
        if (!vault.rotation.exists) revert NoPendingRotation(vaultId);
        delete vault.rotation;
        vault.guardianNonce += 1;
        emit OwnerRotationCancelled(vaultId, msg.sender);
    }

    /// @notice Anyone may trigger an expired vault; the pool is not snapshotted yet.
    function trigger(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (block.timestamp < vault.deadline) revert VaultNotExpired(vaultId);
        uint64 timestamp = _checkedTimestamp(uint64(uint256(vault.config.challengeWindow) + vault.config.sweepPeriod));
        vault.triggered = true;
        vault.triggeredAt = timestamp;
        vault.challengeEnd = timestamp + vault.config.challengeWindow;
        vault.sweepAt = vault.challengeEnd + vault.config.sweepPeriod;
        _clearWithdrawal(vaultId, vault);
        vault.guardianNonce += 1;
        emit Triggered(vaultId, msg.sender, vault.challengeEnd, vault.sweepAt);
    }

    /// @notice Snapshot the pool in ClaimsOpen; claims and sweep also finalize lazily.
    function finalize(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (!vault.triggered || vault.swept) revert NotTriggered(vaultId);
        if (block.timestamp < vault.challengeEnd) revert ChallengeNotOver(vaultId);
        if (vault.finalized) revert AlreadyFinalized(vaultId);
        _finalize(vaultId, vault);
    }

    /// @notice Beneficiary-only payout routing; zero restores the beneficiary itself.
    /// @dev Changes the destination, never the claim identity or allocation.
    function setPayoutAddress(uint256 vaultId, address payout) external nonReentrant {
        _requireVault(vaultId);
        if (_sharesBps[vaultId][msg.sender] == 0) revert NotBeneficiary(vaultId, msg.sender);
        if (_claimed[vaultId][msg.sender]) revert AlreadyClaimed(vaultId, msg.sender);
        if (payout == address(this)) revert InvalidPayoutAddress();
        _payoutAddresses[vaultId][msg.sender] = payout;
        emit PayoutAddressSet(vaultId, msg.sender, payout);
    }

    /// @notice Fallback-only sweep routing in any unswept phase; zero restores the fallback itself.
    /// @dev Changes the destination, never the immutable fallback identity.
    function setFallbackPayout(uint256 vaultId, address payout) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (msg.sender != vault.config.fallbackAddress) revert NotFallback(vaultId);
        if (vault.swept) revert VaultSwept(vaultId);
        if (payout == address(this)) revert InvalidPayoutAddress();
        vault.fallbackPayout = payout;
        emit FallbackPayoutSet(vaultId, payout);
    }

    /// @notice Consume the caller's claim until swept; the last claimant receives dust.
    /// @dev Zero payouts still consume a claim and skip the token transfer.
    function claim(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        uint16 share = _sharesBps[vaultId][msg.sender];
        if (share == 0) revert NotBeneficiary(vaultId, msg.sender);
        if (vault.swept) revert VaultSwept(vaultId);
        if (!vault.triggered) revert VaultNotTriggered(vaultId);
        if (block.timestamp < vault.challengeEnd) revert ChallengeNotOver(vaultId);
        if (_claimed[vaultId][msg.sender]) revert AlreadyClaimed(vaultId, msg.sender);
        _finalize(vaultId, vault);
        uint256 amount = _claimAmount(vaultId, vault, share);
        address payoutTo = _payoutAddress(vaultId, msg.sender);
        _claimed[vaultId][msg.sender] = true;
        vault.claimedCount += 1;
        vault.totalClaimed += amount;
        totalPaidOut += amount;
        emit Claimed(vaultId, msg.sender, payoutTo, amount);
        if (amount != 0) usdc.safeTransfer(payoutTo, amount);
    }

    /// @notice Anyone may send remaining allocation to the effective fallback payout at or after sweepAt.
    function sweep(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (vault.swept) revert AlreadySwept(vaultId);
        if (!vault.triggered || block.timestamp < vault.sweepAt) revert SweepNotReady(vaultId);
        _finalize(vaultId, vault);
        uint256 amount = vault.claimPool - vault.totalClaimed;
        vault.swept = true;
        totalPaidOut += amount;
        address payoutTo = vault.fallbackPayout == address(0) ? vault.config.fallbackAddress : vault.fallbackPayout;
        emit Swept(vaultId, msg.sender, payoutTo, amount);
        if (amount != 0) usdc.safeTransfer(payoutTo, amount);
    }

    /// @notice Return a snapshot of all vault timing and accounting fields.
    function getVault(uint256 vaultId) external view returns (VaultView memory result) {
        Vault storage vault = _requireVault(vaultId);
        result.owner = vault.owner;
        result.lastCheckIn = vault.lastCheckIn;
        result.interval = vault.interval;
        result.deadline = vault.deadline;
        result.balance = vault.balance;
        result.claimPool = vault.claimPool;
        result.totalClaimed = vault.totalClaimed;
        result.claimedCount = vault.claimedCount;
        result.triggered = vault.triggered;
        result.triggeredAt = vault.triggeredAt;
        result.challengeEnd = vault.challengeEnd;
        result.sweepAt = vault.sweepAt;
        result.finalized = vault.finalized;
        result.swept = vault.swept;
        result.checkInDelegate = vault.checkInDelegate;
        result.guardianNonce = vault.guardianNonce;
        result.extensionUsed = vault.extensionUsed;
        result.beneficiaryCount = _beneficiaries[vaultId].length;
        result.phase = _phase(vault);
    }

    /// @notice Return immutable resolved delays, fallback and guardian configuration.
    function getConfig(uint256 vaultId) external view returns (ConfigView memory) {
        return _requireVault(vaultId).config;
    }

    /// @notice Return the permanent beneficiaries and their matching shares.
    /// @param vaultId Existing vault identifier.
    /// @return beneficiaries Addresses in creation order.
    /// @return sharesBps Corresponding basis-point allocations.
    function getBeneficiaries(uint256 vaultId)
        external
        view
        returns (address[] memory beneficiaries, uint16[] memory sharesBps)
    {
        _requireVault(vaultId);
        beneficiaries = _beneficiaries[vaultId];
        sharesBps = new uint16[](beneficiaries.length);
        for (uint256 i; i < beneficiaries.length; ++i) {
            sharesBps[i] = _sharesBps[vaultId][beneficiaries[i]];
        }
    }

    /// @notice Return the fixed guardian addresses in creation order.
    function getGuardians(uint256 vaultId) external view returns (address[] memory) {
        _requireVault(vaultId);
        return _guardians[vaultId];
    }

    /// @notice Whether an address belongs to the fixed guardian set.
    function isGuardian(uint256 vaultId, address account) external view returns (bool) {
        _requireVault(vaultId);
        return _isGuardian[vaultId][account];
    }

    /// @notice Return the queued withdrawal, or a zero-valued struct if absent.
    function getPendingWithdrawal(uint256 vaultId) external view returns (PendingWithdrawal memory) {
        return _requireVault(vaultId).withdrawal;
    }

    /// @notice Return the queued owner rotation including proposedAt and approved, or a zero-valued struct if absent.
    /// @dev proposedAt is informational; only explicit owner/delegate approval authorizes the exact newOwner.
    function getPendingRotation(uint256 vaultId) external view returns (PendingRotation memory) {
        return _requireVault(vaultId).rotation;
    }

    /// @notice Historical approval count; old-nonce action IDs cannot execute new actions.
    function approvalCount(uint256 vaultId, bytes32 actionId) external view returns (uint256) {
        _requireVault(vaultId);
        return _approvalCounts[vaultId][actionId];
    }

    /// @notice Historical record of whether this guardian approved this exact action ID.
    function hasApproved(uint256 vaultId, bytes32 actionId, address guardian) external view returns (bool) {
        _requireVault(vaultId);
        return _approved[vaultId][actionId][guardian];
    }

    /// @notice Effective payout destination; an unset override returns the supplied address.
    function payoutAddressOf(uint256 vaultId, address beneficiary) external view returns (address) {
        _requireVault(vaultId);
        return _payoutAddress(vaultId, beneficiary);
    }

    /// @notice Effective fallback sweep destination; an unset override returns the immutable fallback.
    function fallbackPayoutOf(uint256 vaultId) external view returns (address) {
        Vault storage vault = _requireVault(vaultId);
        return vault.fallbackPayout == address(0) ? vault.config.fallbackAddress : vault.fallbackPayout;
    }

    /// @notice Current phase, using inclusive deadline, challenge-end and sweep boundaries.
    /// @dev ClaimsOpen lasts from challengeEnd until sweep executes.
    function phase(uint256 vaultId) external view returns (Phase) {
        return _phase(_requireVault(vaultId));
    }

    /// @notice Whether the current deadline has been reached.
    function isExpired(uint256 vaultId) external view returns (bool expired) {
        return block.timestamp >= _requireVault(vaultId).deadline;
    }

    /// @notice Return the explicitly stored inclusive expiration timestamp.
    function deadline(uint256 vaultId) external view returns (uint256 timestamp) {
        return _requireVault(vaultId).deadline;
    }

    /// @notice Amount currently claimable; zero outside the claim window or after a claim.
    /// @dev Uses balance before lazy finalization; the last actual claimant receives dust.
    function claimable(uint256 vaultId, address account) external view returns (uint256 amount) {
        Vault storage vault = _requireVault(vaultId);
        uint16 share = _sharesBps[vaultId][account];
        if (!vault.triggered || vault.swept || block.timestamp < vault.challengeEnd
            || share == 0 || _claimed[vaultId][account]) return 0;
        return _claimAmount(vaultId, vault, share);
    }

    /// @notice Whether an account has consumed its claim, even for a zero payout.
    /// @param vaultId Existing vault identifier.
    /// @param account Account to query; non-beneficiaries return false.
    /// @return claimed True only after a successful claim.
    function hasClaimed(uint256 vaultId, address account) external view returns (bool claimed) {
        _requireVault(vaultId);
        return _claimed[vaultId][account];
    }

    /// @notice Return the total number of created vaults.
    /// @return count Number of existing vaults; none can be deleted.
    function vaultCount() external view returns (uint256 count) {
        return nextVaultId - 1;
    }

    /// @dev Resolve vault storage or revert for an unknown identifier.
    function _requireVault(uint256 vaultId) private view returns (Vault storage vault) {
        vault = _vaults[vaultId];
        if (vault.owner == address(0)) revert VaultNotFound(vaultId);
    }

    function _requireOwner(uint256 vaultId, Vault storage vault) private view {
        if (msg.sender != vault.owner) revert NotVaultOwner(vaultId);
    }

    function _requireActive(uint256 vaultId, Vault storage vault) private view {
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (block.timestamp >= vault.deadline) revert VaultExpired(vaultId);
    }

    function _requireGuardian(uint256 vaultId) private view {
        if (!_isGuardian[vaultId][msg.sender]) revert NotGuardian(vaultId);
    }

    /// @dev Count one vote; consume the shared nonce when quorum is reached.
    function _approve(uint256 vaultId, Vault storage vault, bytes32 actionId) private returns (bool) {
        _requireGuardian(vaultId);
        if (_approved[vaultId][actionId][msg.sender]) revert AlreadyApproved(vaultId, actionId, msg.sender);
        _approved[vaultId][actionId][msg.sender] = true;
        uint256 approvals = ++_approvalCounts[vaultId][actionId];
        uint8 threshold = vault.config.guardianThreshold;
        emit GuardianApproved(vaultId, msg.sender, actionId, approvals, threshold);
        if (approvals < threshold) return false;
        vault.guardianNonce += 1;
        return true;
    }

    /// @dev Clear a withdrawal; callers invalidate votes once per executed transition.
    function _clearWithdrawal(uint256 vaultId, Vault storage vault) private {
        if (!vault.withdrawal.exists) return;
        delete vault.withdrawal;
        emit WithdrawCancelled(vaultId, msg.sender);
    }

    /// @dev Idempotent snapshot; callers enforce the required phase/window first.
    function _finalize(uint256 vaultId, Vault storage vault) private {
        if (vault.finalized) return;
        vault.claimPool = vault.balance;
        vault.balance = 0;
        vault.finalized = true;
        emit Finalized(vaultId, vault.claimPool);
    }

    function _phase(Vault storage vault) private view returns (Phase) {
        if (vault.swept) return Phase.Swept;
        if (vault.triggered) {
            return block.timestamp < vault.challengeEnd ? Phase.Challenge : Phase.ClaimsOpen;
        }
        return block.timestamp < vault.deadline ? Phase.Active : Phase.Expired;
    }

    function _payoutAddress(uint256 vaultId, address beneficiary) private view returns (address) {
        address payout = _payoutAddresses[vaultId][beneficiary];
        return payout == address(0) ? beneficiary : payout;
    }

    /// @dev Compute floor allocation without multiplication overflow, or final remainder.
    function _claimAmount(uint256 vaultId, Vault storage vault, uint16 share) private view returns (uint256) {
        uint256 pool = vault.finalized ? vault.claimPool : vault.balance;
        if (vault.claimedCount + 1 == _beneficiaries[vaultId].length) {
            return pool - vault.totalClaimed;
        }
        return Math.mulDiv(pool, uint256(share), BPS_DENOMINATOR);
    }

    /// @dev Validate timestamp conversion and uint64 future-timestamp representability.
    function _checkedTimestamp(uint64 duration) private view returns (uint64 timestamp) {
        if (block.timestamp > uint256(type(uint64).max) - uint256(duration)) revert TimestampOverflow();
        return uint64(block.timestamp);
    }

    function _futureTimestamp(uint64 duration) private view returns (uint64) {
        return _checkedTimestamp(duration) + duration;
    }

    function _resolveDelay(uint64 value, uint64 defaultValue, uint64 maximum) private pure returns (uint64) {
        if (value == 0) return defaultValue;
        if (value < MIN_DELAY || value > maximum) revert InvalidDelay(value);
        return value;
    }

    function _storeBeneficiaries(uint256 vaultId, CreateParams calldata p) private {
        uint256 count = p.beneficiaries.length;
        if (count == 0) revert EmptyBeneficiaries();
        if (count != p.sharesBps.length) revert LengthMismatch();
        if (count > MAX_BENEFICIARIES) revert TooManyBeneficiaries();
        uint256 total;
        for (uint256 i; i < count; ++i) {
            address beneficiary = p.beneficiaries[i];
            uint16 share = p.sharesBps[i];
            if (beneficiary == address(0)) revert ZeroBeneficiary();
            if (_sharesBps[vaultId][beneficiary] != 0) revert DuplicateBeneficiary(beneficiary);
            if (share == 0) revert ZeroShare(beneficiary);
            _sharesBps[vaultId][beneficiary] = share;
            _beneficiaries[vaultId].push(beneficiary);
            total += share;
        }
        if (total != BPS_DENOMINATOR) revert InvalidSharesTotal(total);
    }

    function _storeGuardians(uint256 vaultId, CreateParams calldata p) private {
        uint256 count = p.guardians.length;
        if (count > MAX_GUARDIANS) revert TooManyGuardians();
        if ((count == 0 && p.guardianThreshold != 0)
            || (count != 0 && (p.guardianThreshold == 0 || p.guardianThreshold > count))) {
            revert InvalidGuardianThreshold(p.guardianThreshold);
        }
        for (uint256 i; i < count; ++i) {
            address guardian = p.guardians[i];
            if (guardian == address(0)) revert ZeroGuardian();
            if (guardian == msg.sender) revert GuardianIsOwner();
            if (_isGuardian[vaultId][guardian]) revert DuplicateGuardian(guardian);
            _isGuardian[vaultId][guardian] = true;
            _guardians[vaultId].push(guardian);
        }
    }

    /// @dev Emit all creation fields together, replacing default sentinels with resolved values.
    function _emitVaultCreated(uint256 vaultId, CreateParams calldata p, ConfigView storage config) private {
        CreateParams memory resolved = p;
        resolved.withdrawDelay = config.withdrawDelay;
        resolved.challengeWindow = config.challengeWindow;
        resolved.rotationTimelock = config.rotationTimelock;
        resolved.sweepPeriod = config.sweepPeriod;
        emit VaultCreated(vaultId, msg.sender, resolved);
    }
}
