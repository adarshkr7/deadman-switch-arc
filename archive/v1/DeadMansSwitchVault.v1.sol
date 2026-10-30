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
 * Deposits remain possible after expiry until trigger, and never reset the timer.
 * Direct token transfers are not credited to any vault and cannot be recovered.
 * The configured token is trusted to have USDC's non-rebasing transfer semantics;
 * balance-delta accounting additionally avoids overcrediting taxed inbound transfers.
 */
contract DeadMansSwitchVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Basis points representing the entire claim pool.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Shortest supported check-in interval, in seconds.
    uint64 public constant MIN_INTERVAL = 60;
    /// @notice Longest supported interval: 100 periods of 365 days.
    uint64 public constant MAX_INTERVAL = 100 * 365 days;
    /// @notice Maximum beneficiaries per vault, bounding creation and view loops.
    uint256 public constant MAX_BENEFICIARIES = 20;
    /// @notice The immutable USDC token used by every vault.
    IERC20 public immutable usdc;
    /// @notice Next vault identifier; identifiers begin at one.
    uint256 public nextVaultId = 1;

    /// @dev Persistent accounting for one vault; owner zero means nonexistent.
    struct Vault {
        /// @dev Immutable creator authorized to check in and withdraw while live.
        address owner;
        /// @dev Most recent creation/check-in timestamp.
        uint64 lastCheckIn;
        /// @dev Immutable interval in seconds.
        uint64 interval;
        /// @dev Whether the expired vault has been irreversibly triggered.
        bool triggered;
        /// @dev Number of beneficiaries who have claimed, including zero payouts.
        uint256 claimedCount;
        /// @dev Untriggered deposits less withdrawals; zero after trigger.
        uint256 balance;
        /// @dev Immutable total allocation snapshotted at trigger.
        uint256 claimPool;
        /// @dev Aggregate payouts booked after trigger.
        uint256 totalClaimed;
    }

    /// @notice Complete accounting and timing returned by getVault.
    struct VaultView {
        /// @notice Creator of this vault.
        address owner;
        /// @notice Most recent creation/check-in timestamp.
        uint64 lastCheckIn;
        /// @notice Fixed check-in interval in seconds.
        uint64 interval;
        /// @notice Expiration timestamp, inclusive.
        uint256 deadline;
        /// @notice Currently withdrawable accounting balance, before trigger.
        uint256 balance;
        /// @notice Total distributable allocation fixed at trigger.
        uint256 claimPool;
        /// @notice Aggregate beneficiary payouts.
        uint256 totalClaimed;
        /// @notice Number of completed claims.
        uint256 claimedCount;
        /// @notice Whether the vault has been triggered.
        bool triggered;
        /// @notice Number of fixed beneficiaries.
        uint256 beneficiaryCount;
    }

    /// @dev Vault accounting indexed by its identifier.
    mapping(uint256 => Vault) private _vaults;
    /// @dev Fixed beneficiary enumeration for each vault.
    mapping(uint256 => address[]) private _beneficiaries;
    /// @dev Fixed nonzero allocation; zero denotes a non-beneficiary.
    mapping(uint256 => mapping(address => uint16)) private _sharesBps;
    /// @dev Whether an account has consumed its single claim.
    mapping(uint256 => mapping(address => bool)) private _claimed;

    /// @notice The configured token address cannot be zero.
    error ZeroTokenAddress();
    /// @notice No vault exists with the supplied identifier.
    error VaultNotFound(uint256 vaultId);
    /// @notice At least one beneficiary is required.
    error EmptyBeneficiaries();
    /// @notice Beneficiary and share arrays must have identical lengths.
    error LengthMismatch();
    /// @notice The beneficiary cap was exceeded.
    error TooManyBeneficiaries();
    /// @notice A beneficiary cannot be the zero address.
    error ZeroBeneficiary();
    /// @notice A beneficiary occurs more than once.
    error DuplicateBeneficiary(address beneficiary);
    /// @notice Every beneficiary must have a positive share.
    error ZeroShare(address beneficiary);
    /// @notice Shares must sum to exactly 10,000 basis points.
    error InvalidSharesTotal(uint256 total);
    /// @notice The interval lies outside the supported bounds.
    error InvalidInterval(uint64 interval);
    /// @notice The timestamp and interval cannot fit a uint64 deadline.
    error TimestampOverflow();
    /// @notice Only the vault's creator may perform this operation.
    error NotVaultOwner(uint256 vaultId);
    /// @notice The vault is expired, including exactly at its deadline.
    error VaultExpired(uint256 vaultId);
    /// @notice Triggering requires the vault to have expired.
    error VaultNotExpired(uint256 vaultId);
    /// @notice The vault has already been triggered.
    error VaultAlreadyTriggered(uint256 vaultId);
    /// @notice Claiming requires the vault to have been triggered.
    error VaultNotTriggered(uint256 vaultId);
    /// @notice The requested amount must be positive.
    error ZeroAmount();
    /// @notice A deposit must increase the token balance.
    error NoTokensReceived();
    /// @notice The withdrawal exceeds the vault's balance.
    error InsufficientVaultBalance(uint256 available, uint256 requested);
    /// @notice The caller is not a beneficiary of this vault.
    error NotBeneficiary(uint256 vaultId, address account);
    /// @notice This beneficiary has already claimed.
    error AlreadyClaimed(uint256 vaultId, address account);

    /// @notice A vault was created with permanent beneficiaries and shares.
    event VaultCreated(
        uint256 indexed vaultId,
        address indexed owner,
        address[] beneficiaries,
        uint16[] sharesBps,
        uint64 interval
    );
    /// @notice Tokens were deposited; amount is the actual received amount.
    event Deposited(uint256 indexed vaultId, address indexed from, uint256 amount);
    /// @notice The creator reset the check-in timer.
    event CheckedIn(uint256 indexed vaultId, uint256 timestamp, uint256 newDeadline);
    /// @notice The creator withdrew tokens without resetting the timer.
    event Withdrawn(uint256 indexed vaultId, uint256 amount);
    /// @notice An expired vault's distribution pool was irreversibly fixed.
    event Triggered(uint256 indexed vaultId, address indexed caller, uint256 claimPool);
    /// @notice A beneficiary consumed their claim, possibly receiving zero tokens.
    event Claimed(uint256 indexed vaultId, address indexed beneficiary, uint256 amount);

    /// @notice Configure the immutable token; deployment on Arc must pass its USDC predeploy.
    /// @param usdc_ USDC ERC-20 address, or a mock token for testing.
    constructor(IERC20 usdc_) {
        if (address(usdc_) == address(0)) revert ZeroTokenAddress();
        usdc = usdc_;
    }

    /// @notice Create an empty vault owned by the caller with immutable beneficiaries.
    /// @param beneficiaries Unique nonzero beneficiary addresses, at most 20.
    /// @param sharesBps Positive corresponding shares summing to 10,000.
    /// @param interval Check-in interval, from 60 seconds through 100 years.
    /// @return vaultId Newly assigned identifier, starting at one.
    function createVault(
        address[] calldata beneficiaries,
        uint16[] calldata sharesBps,
        uint64 interval
    ) external nonReentrant returns (uint256 vaultId) {
        uint256 count = beneficiaries.length;
        if (count == 0) revert EmptyBeneficiaries();
        if (count != sharesBps.length) revert LengthMismatch();
        if (count > MAX_BENEFICIARIES) revert TooManyBeneficiaries();
        if (interval < MIN_INTERVAL || interval > MAX_INTERVAL) revert InvalidInterval(interval);
        uint64 timestamp = _checkedTimestamp(interval);

        vaultId = nextVaultId++;
        uint256 total;
        for (uint256 i; i < count; ++i) {
            address beneficiary = beneficiaries[i];
            uint16 share = sharesBps[i];
            if (beneficiary == address(0)) revert ZeroBeneficiary();
            if (_sharesBps[vaultId][beneficiary] != 0) revert DuplicateBeneficiary(beneficiary);
            if (share == 0) revert ZeroShare(beneficiary);
            _sharesBps[vaultId][beneficiary] = share;
            _beneficiaries[vaultId].push(beneficiary);
            total += share;
        }
        if (total != BPS_DENOMINATOR) revert InvalidSharesTotal(total);

        Vault storage vault = _vaults[vaultId];
        vault.owner = msg.sender;
        vault.lastCheckIn = timestamp;
        vault.interval = interval;
        emit VaultCreated(vaultId, msg.sender, beneficiaries, sharesBps, interval);
    }

    /// @notice Deposit into an existing vault, including after expiry but before trigger.
    /// @dev Requires prior token approval. Never resets the timer, even for the owner.
    /// The balance delta must be observed after transfer; the global reentrancy guard
    /// prevents other state transitions during that interaction before crediting funds.
    /// @param vaultId Existing vault identifier.
    /// @param amount Positive requested transfer amount in token base units.
    function deposit(uint256 vaultId, uint256 amount) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = usdc.balanceOf(address(this));
        if (afterBalance <= beforeBalance) revert NoTokensReceived();
        uint256 received = afterBalance - beforeBalance;
        vault.balance += received;
        emit Deposited(vaultId, msg.sender, received);
    }

    /// @notice Reset the timer as owner strictly before the current deadline.
    /// @param vaultId Existing vault identifier.
    function checkIn(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        _requireLiveOwner(vaultId, vault);
        vault.lastCheckIn = _checkedTimestamp(vault.interval);
        emit CheckedIn(vaultId, block.timestamp, _deadline(vault));
    }

    /// @notice Withdraw as owner strictly before expiry without resetting the timer.
    /// @param vaultId Existing vault identifier.
    /// @param amount Positive amount, no greater than the vault's accounting balance.
    function withdraw(uint256 vaultId, uint256 amount) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        _requireLiveOwner(vaultId, vault);
        if (amount == 0) revert ZeroAmount();
        if (amount > vault.balance) revert InsufficientVaultBalance(vault.balance, amount);
        vault.balance -= amount;
        emit Withdrawn(vaultId, amount);
        usdc.safeTransfer(vault.owner, amount);
    }

    /// @notice Irreversibly fix the pool of an expired vault; callable by anyone.
    /// @dev Triggering is allowed exactly at the deadline, including for empty vaults.
    /// @param vaultId Existing vault identifier.
    function trigger(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (block.timestamp < _deadline(vault)) revert VaultNotExpired(vaultId);
        vault.triggered = true;
        vault.claimPool = vault.balance;
        vault.balance = 0;
        emit Triggered(vaultId, msg.sender, vault.claimPool);
    }

    /// @notice Pull the caller's allocation once after trigger.
    /// @dev The last actual claimant receives all remaining rounding dust, regardless
    /// of array order. Zero payouts still consume a claim and skip the token transfer.
    /// @param vaultId Existing vault identifier.
    function claim(uint256 vaultId) external nonReentrant {
        Vault storage vault = _requireVault(vaultId);
        if (!vault.triggered) revert VaultNotTriggered(vaultId);
        uint16 share = _sharesBps[vaultId][msg.sender];
        if (share == 0) revert NotBeneficiary(vaultId, msg.sender);
        if (_claimed[vaultId][msg.sender]) revert AlreadyClaimed(vaultId, msg.sender);

        uint256 amount = _claimAmount(vaultId, vault, share);
        _claimed[vaultId][msg.sender] = true;
        vault.claimedCount += 1;
        vault.totalClaimed += amount;
        emit Claimed(vaultId, msg.sender, amount);
        if (amount != 0) usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Return a snapshot of all vault timing and accounting fields.
    /// @param vaultId Existing vault identifier.
    /// @return result Vault details, including its deadline and beneficiary count.
    function getVault(uint256 vaultId) external view returns (VaultView memory result) {
        Vault storage vault = _requireVault(vaultId);
        result = VaultView({
            owner: vault.owner,
            lastCheckIn: vault.lastCheckIn,
            interval: vault.interval,
            deadline: _deadline(vault),
            balance: vault.balance,
            claimPool: vault.claimPool,
            totalClaimed: vault.totalClaimed,
            claimedCount: vault.claimedCount,
            triggered: vault.triggered,
            beneficiaryCount: _beneficiaries[vaultId].length
        });
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

    /// @notice Whether the deadline has been reached; remains true after trigger.
    /// @param vaultId Existing vault identifier.
    /// @return expired True when block.timestamp is at least the deadline.
    function isExpired(uint256 vaultId) external view returns (bool expired) {
        return block.timestamp >= _deadline(_requireVault(vaultId));
    }

    /// @notice Return the inclusive expiration timestamp.
    /// @param vaultId Existing vault identifier.
    /// @return timestamp The current check-in timestamp plus the fixed interval.
    function deadline(uint256 vaultId) external view returns (uint256 timestamp) {
        return _deadline(_requireVault(vaultId));
    }

    /// @notice Return the amount an account would receive if it claimed now.
    /// @dev Returns zero before trigger, for non-beneficiaries, or after a claim.
    /// A later claim may receive different rounding dust if it becomes the last claim.
    /// @param vaultId Existing vault identifier.
    /// @param account Account whose potential allocation is requested.
    /// @return amount Current payout, including any last-claim remainder.
    function claimable(uint256 vaultId, address account) external view returns (uint256 amount) {
        Vault storage vault = _requireVault(vaultId);
        uint16 share = _sharesBps[vaultId][account];
        if (!vault.triggered || share == 0 || _claimed[vaultId][account]) return 0;
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
    /// @param vaultId Identifier to resolve.
    /// @return vault Storage reference to the existing vault.
    function _requireVault(uint256 vaultId) private view returns (Vault storage vault) {
        vault = _vaults[vaultId];
        if (vault.owner == address(0)) revert VaultNotFound(vaultId);
    }

    /// @dev Require ownership and a live, untriggered vault.
    /// @param vaultId Identifier used for error reporting.
    /// @param vault Existing vault storage reference.
    function _requireLiveOwner(uint256 vaultId, Vault storage vault) private view {
        if (msg.sender != vault.owner) revert NotVaultOwner(vaultId);
        if (vault.triggered) revert VaultAlreadyTriggered(vaultId);
        if (block.timestamp >= _deadline(vault)) revert VaultExpired(vaultId);
    }

    /// @dev Widen before adding, avoiding narrow arithmetic overflow.
    /// @param vault Existing vault storage reference.
    /// @return timestamp Inclusive expiration timestamp.
    function _deadline(Vault storage vault) private view returns (uint256 timestamp) {
        return uint256(vault.lastCheckIn) + uint256(vault.interval);
    }

    /// @dev Validate timestamp conversion and uint64 deadline representability.
    /// @param interval Interval that will be added to the current timestamp.
    /// @return timestamp Current timestamp safely narrowed to uint64.
    function _checkedTimestamp(uint64 interval) private view returns (uint64 timestamp) {
        if (block.timestamp > uint256(type(uint64).max) - uint256(interval)) revert TimestampOverflow();
        return uint64(block.timestamp);
    }

    /// @dev Compute floor allocation without multiplication overflow, or final remainder.
    /// @param vaultId Existing vault identifier.
    /// @param vault Existing, triggered vault storage reference.
    /// @param share Positive share belonging to an unclaimed beneficiary.
    /// @return amount Payout for this beneficiary if they claim next.
    function _claimAmount(uint256 vaultId, Vault storage vault, uint16 share)
        private
        view
        returns (uint256 amount)
    {
        if (vault.claimedCount + 1 == _beneficiaries[vaultId].length) {
            return vault.claimPool - vault.totalClaimed;
        }
        return Math.mulDiv(vault.claimPool, uint256(share), BPS_DENOMINATOR);
    }
}
