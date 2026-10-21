// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMugiHistoricalToken is IERC20 {
    /// @notice Last balance/supply strictly before the timestamp, excluding all writes at that timestamp.
    function balanceBefore(address account, uint64 cutoff) external view returns (uint256);
    function totalSupplyBefore(uint64 cutoff) external view returns (uint256);
}

/// @notice Lazy accounting for a ten-crew season, with ownership fixed at each round's original cutoff.
/// @dev Ordinary token transfers never call this ledger and never change a past round.
/// The immutable hook permits token claims only before the next cutoff, or after
/// finalization. A cutoff must also be later than every prior virtual-accounting
/// mutation: materialization and its physical transfer cannot straddle a snapshot.
contract MugiIMDLedger {
    uint256 public constant SCALE = 95_126_814_720; // 4**9 * 9!
    uint8 public constant TOKEN_COUNT = 10;
    uint16 private constant ALL_TOKENS = 1023;

    /// @dev Flat static constructor tuple; no external calls or deployed dependencies are required.
    struct Configuration {
        address hook;
        address token0;
        address token1;
        address token2;
        address token3;
        address token4;
        address token5;
        address token6;
        address token7;
        address token8;
        address token9;
        address airdrop;
        address engine;
        address team;
        address community;
        address manager;
    }

    struct Account {
        uint256[10] virtualScaled;
        uint256 earnedEth;
        uint8 cursor;
    }

    struct Round {
        uint256[10] eligibleScaled;
        uint256 rewardPerCrew;
        uint64 cutoff;
        uint16 survivorMask;
        uint8 survivorCount;
        uint8 loser;
        bool finale;
    }

    struct State {
        address[10] tokens;
        address[7] excludedAccounts;
        uint256[10] terminalSupply;
        uint256[10] virtualScaled;
        uint256[10] escrowBacking;
        mapping(address => bool) excluded;
        mapping(address => Account) accounts;
        Round[10] rounds;
        uint256 reservedEth;
        uint256 unallocatedEth;
        uint256 lastVirtualChangeAt;
        uint64 lastCutoff;
        uint16 aliveMask;
        uint8 excludedCount;
        uint8 eventCount;
        uint8 eliminationCount;
        bool finalized;
        bool claimsExpired;
    }

    address public immutable hook;
    bytes32 public immutable configurationHash;
    State private self;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidRound();
    error InvalidToken();
    error InvalidClaim();
    error InexactConversion();

    constructor(Configuration memory c) {
        if (c.hook == address(0) || c.airdrop == address(0) || c.engine == address(0)
            || c.team == address(0) || c.community == address(0) || c.manager == address(0)) {
            revert InvalidConfiguration();
        }
        hook = c.hook;
        configurationHash = keccak256(abi.encode(c));
        self.excluded[address(0)] = true;
        _exclude(c.hook);
        _exclude(address(this));
        _exclude(c.airdrop);
        _exclude(c.engine);
        _exclude(c.team);
        _exclude(c.community);
        _exclude(c.manager);
        address[10] memory tokens = [c.token0, c.token1, c.token2, c.token3, c.token4,
            c.token5, c.token6, c.token7, c.token8, c.token9];
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            if (self.excluded[tokens[i]]) revert InvalidConfiguration();
            for (uint8 j; j < i; ++j) {
                if (tokens[i] == tokens[j]) revert InvalidConfiguration();
            }
        }
        self.tokens = tokens;
        self.aliveMask = ALL_TOKENS;
    }

    modifier onlyHook() { if (msg.sender != hook) revert Unauthorized(); _; }
    function reservedEth() external view returns (uint256) { return self.reservedEth; }
    function escrowBacking(uint8 crew) external view returns (uint256) { return self.escrowBacking[crew]; }

    /// @param aliveMask The PRE-elimination alive mask, checked against state.
    /// @param cutoff Original scheduled cutoff, not the request/fulfillment/settlement time.
    /// @return reserveRequired Additional preminted tokens to earmark as claim backing per crew.
    /// @return oldEscrowBurn Physical loser escrow backing to retire once.
    /// @dev The hook completes backing/burn operations atomically. No tokens are minted.
    function recordElimination(uint8 loser, uint16 aliveMask, uint256 treasureWei, uint64 cutoff)
        public onlyHook
        returns (uint256[10] memory reserveRequired, uint256 oldEscrowBurn)
    {
        if (self.finalized || self.eliminationCount >= 9 || loser >= TOKEN_COUNT
            || aliveMask != self.aliveMask || (aliveMask & (uint16(1) << loser)) == 0) {
            revert InvalidRound();
        }
        _acceptCutoff(cutoff);
        uint16 survivors = aliveMask & ~(uint16(1) << loser);
        uint8 count = _count(survivors);
        if (count == 0) revert InvalidRound();

        Round storage round = self.rounds[self.eventCount];
        round.cutoff = cutoff;
        round.loser = loser;
        round.survivorMask = survivors;
        round.survivorCount = count;
        _recordRewards(round, treasureWei);

        uint256 allocation = _convert(_walletBefore(loser, cutoff) + self.virtualScaled[loser], count);
        oldEscrowBurn = self.escrowBacking[loser];
        self.virtualScaled[loser] = 0;
        self.escrowBacking[loser] = 0;
        self.aliveMask = survivors;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            if ((survivors & (uint16(1) << i)) == 0) continue;
            self.virtualScaled[i] += allocation;
            uint256 needed = _ceilTokens(self.virtualScaled[i]);
            reserveRequired[i] = needed - self.escrowBacking[i];
            self.escrowBacking[i] = needed;
        }
        ++self.eventCount;
        ++self.eliminationCount;
    }

    /// @notice Stops new rounds, retaining earned token claims and freezing the final denominator.
    function finalizeMigration(uint8 finalToken, uint64 cutoff) public onlyHook {
        if (self.finalized || self.eliminationCount != 9 || finalToken >= TOKEN_COUNT
            || self.aliveMask != (uint16(1) << finalToken)) revert InvalidRound();
        _acceptCutoff(cutoff);
        self.terminalSupply[finalToken] = _walletBefore(finalToken, cutoff) + self.virtualScaled[finalToken];
        self.finalized = true;
    }

    /// @notice Equal recovered-ETH shares per live crew, pro rata to original-cutoff wallet plus virtual supply.
    /// @dev Earlier rewards/backing remain reserved. Empty-crew shares and division
    /// dust are unallocated. The hook enforces recovery timing and claim expiration.
    function emergencyFinalize(uint16 aliveMask, uint256 recoveryWei, uint64 cutoff) public onlyHook {
        if (self.finalized || aliveMask == 0 || aliveMask != self.aliveMask || self.eventCount >= TOKEN_COUNT) {
            revert InvalidRound();
        }
        _acceptCutoff(cutoff);
        Round storage round = self.rounds[self.eventCount];
        round.cutoff = cutoff;
        round.finale = true;
        round.survivorMask = aliveMask;
        round.survivorCount = _count(aliveMask);
        _recordRewards(round, recoveryWei);
        self.terminalSupply = round.eligibleScaled;
        ++self.eventCount;
        self.finalized = true;
    }

    /// @dev The hook immediately transfers returned amounts from excluded backing
    /// to the same account, atomically; tokens do not invoke ledger callbacks.
    function claimTokens(address account) public onlyHook returns (uint256[10] memory amounts) {
        if (self.claimsExpired || self.excluded[account]) revert InvalidClaim();
        _sync(account);
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            uint256 amount = self.accounts[account].virtualScaled[i] / SCALE;
            if (amount != 0) {
                _debitVirtual(account, i, amount);
                amounts[i] = amount;
            }
        }
    }

    function claimToken(address account, uint8 tokenId, uint256 amount) public onlyHook returns (uint256) {
        if (self.claimsExpired || tokenId >= TOKEN_COUNT || self.excluded[account]) revert InvalidClaim();
        _sync(account);
        if (amount > self.accounts[account].virtualScaled[tokenId] / SCALE) revert InvalidClaim();
        if (amount != 0) _debitVirtual(account, tokenId, amount);
        return amount;
    }

    function claimEth(address account) public onlyHook returns (uint256 amount) {
        if (self.claimsExpired || self.excluded[account]) revert InvalidClaim();
        _sync(account);
        amount = self.accounts[account].earnedEth;
        self.accounts[account].earnedEth = 0;
        self.reservedEth -= amount;
    }

    /// @notice Clears final-season liabilities after the hook's immutable claim deadline.
    function expireFinalClaims()
        public onlyHook
        returns (uint256 expiredEth, uint256[10] memory expiredTokenBacking)
    {
        if (!self.finalized || self.claimsExpired) revert InvalidClaim();
        self.claimsExpired = true;
        expiredEth = self.reservedEth;
        self.reservedEth = 0;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            expiredTokenBacking[i] = self.escrowBacking[i];
            self.escrowBacking[i] = 0;
            self.virtualScaled[i] = 0;
            self.terminalSupply[i] = 0;
        }
    }

    function previewAccount(address account)
        public view
        returns (uint256[10] memory claimableTokens, uint256 earnedEth, uint256[10] memory virtualScaled)
    {
        (virtualScaled, earnedEth) = _preview(account);
        for (uint8 i; i < TOKEN_COUNT; ++i) claimableTokens[i] = virtualScaled[i] / SCALE;
    }

    /// @notice Current live economic supply; defeated crews are zero. Once terminal,
    /// returns the frozen final-cutoff supply, unaffected by later transfers/claims.
    /// @dev Historical rewards always use their own stored cutoff denominator.
    function eligibleSupply(uint8 tokenId) public view returns (uint256) {
        if (tokenId >= TOKEN_COUNT) revert InvalidToken();
        if (self.claimsExpired || (self.aliveMask & (uint16(1) << tokenId)) == 0) return 0;
        if (self.finalized) return self.terminalSupply[tokenId];
        IERC20 token = IERC20(self.tokens[tokenId]);
        uint256 supply = token.totalSupply();
        for (uint8 i; i < self.excludedCount; ++i) supply -= token.balanceOf(self.excludedAccounts[i]);
        return supply * SCALE + self.virtualScaled[tokenId];
    }

    function _exclude(address account) private {
        if (self.excluded[account]) return;
        self.excluded[account] = true;
        self.excludedAccounts[self.excludedCount++] = account;
    }

    function _acceptCutoff(uint64 cutoff) private {
        if (cutoff == 0 || cutoff > block.timestamp || cutoff <= self.lastCutoff
            || cutoff <= self.lastVirtualChangeAt) revert InvalidRound();
        self.lastCutoff = cutoff;
        self.lastVirtualChangeAt = block.timestamp;
    }

    function _walletBefore(uint8 tokenId, uint64 cutoff) private view returns (uint256) {
        IMugiHistoricalToken token = IMugiHistoricalToken(self.tokens[tokenId]);
        uint256 supply = token.totalSupplyBefore(cutoff);
        for (uint8 i; i < self.excludedCount; ++i) {
            supply -= token.balanceBefore(self.excludedAccounts[i], cutoff);
        }
        return supply * SCALE;
    }

    function _recordRewards(Round storage round, uint256 ethAmount) private {
        uint256 share = ethAmount / round.survivorCount;
        round.rewardPerCrew = share;
        uint256 unallocated = ethAmount - share * round.survivorCount;
        for (uint8 i; i < TOKEN_COUNT; ++i) {
            if ((round.survivorMask & (uint16(1) << i)) == 0) continue;
            uint256 supply = _walletBefore(i, round.cutoff) + self.virtualScaled[i];
            round.eligibleScaled[i] = supply;
            if (supply == 0) unallocated += share;
        }
        self.unallocatedEth += unallocated;
        self.reservedEth += ethAmount - unallocated;
    }

    function _debitVirtual(address account, uint8 tokenId, uint256 amount) private {
        uint256 scaled = amount * SCALE;
        self.accounts[account].virtualScaled[tokenId] -= scaled;
        self.virtualScaled[tokenId] -= scaled;
        self.escrowBacking[tokenId] -= amount;
        self.lastVirtualChangeAt = block.timestamp;
    }

    function _sync(address account) private {
        if (self.accounts[account].cursor == self.eventCount) return;
        (uint256[10] memory virtualScaled, uint256 earnedEth) = _preview(account);
        self.accounts[account].virtualScaled = virtualScaled;
        self.accounts[account].earnedEth = earnedEth;
        self.accounts[account].cursor = self.eventCount;
    }

    function _preview(address account)
        private view
        returns (uint256[10] memory virtualScaled, uint256 earnedEth)
    {
        if (self.excluded[account] || self.claimsExpired) return (virtualScaled, 0);
        Account storage stored = self.accounts[account];
        virtualScaled = stored.virtualScaled;
        earnedEth = stored.earnedEth;
        for (uint8 r = stored.cursor; r < self.eventCount; ++r) {
            Round storage round = self.rounds[r];
            for (uint8 i; i < TOKEN_COUNT; ++i) {
                if (round.eligibleScaled[i] == 0) continue;
                uint256 wallet = IMugiHistoricalToken(self.tokens[i]).balanceBefore(account, round.cutoff) * SCALE;
                earnedEth += Math.mulDiv(round.rewardPerCrew, wallet + virtualScaled[i], round.eligibleScaled[i]);
            }
            if (round.finale) continue;
            uint256 loserWallet =
                IMugiHistoricalToken(self.tokens[round.loser]).balanceBefore(account, round.cutoff) * SCALE;
            uint256 allocation = _convert(loserWallet + virtualScaled[round.loser], round.survivorCount);
            virtualScaled[round.loser] = 0;
            for (uint8 i; i < TOKEN_COUNT; ++i) {
                if ((round.survivorMask & (uint16(1) << i)) != 0) virtualScaled[i] += allocation;
            }
        }
    }

    function _convert(uint256 defeatedScaled, uint8 survivors) private pure returns (uint256) {
        uint256 denominator = uint256(survivors) * 4;
        if (mulmod(defeatedScaled, 3, denominator) != 0) revert InexactConversion();
        return Math.mulDiv(defeatedScaled, 3, denominator);
    }

    function _ceilTokens(uint256 scaled) private pure returns (uint256) {
        return scaled / SCALE + (scaled % SCALE == 0 ? 0 : 1);
    }

    function _count(uint16 mask) private pure returns (uint8 result) {
        for (; mask != 0; mask &= mask - 1) ++result;
    }
}
