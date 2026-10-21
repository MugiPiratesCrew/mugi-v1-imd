// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IMugiIMDBuybackPlanVerifier {
    function verify(bytes32 planHash, bytes calldata proof, address consumer) external view returns (bool);
}

/// @notice Hook-authorized budget accounting using ordinary calls. ETH stays in the hook.
contract MugiIMDBuybacks {
    struct BuybackPlan {
        uint64 roundId;
        uint64 nonce;
        uint64 deadline;
        uint256[10] allocations;
    }

    struct Budget {
        uint256 total;
        uint256 spent;
        uint64 deadline;
        uint64 planValidUntil;
        uint64 nonce;
        uint16 aliveMask;
        uint256[10] allocation;
        uint256[10] crewSpent;
        uint64[10] lastTrade;
        uint256 authorizedAmount;
        uint8 authorizedCrew;
        bool authorizationPending;
    }

    struct State {
        mapping(uint64 => Budget) rounds;
    }

    address public immutable hook;
    State private self;
    error InvalidHook();
    error NotHook();

    constructor(address hook_) {
        if (hook_ == address(0)) revert InvalidHook();
        hook = hook_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    function roundBudget(uint64 roundId) external view returns (Budget memory) {
        return self.rounds[roundId];
    }
    error InvalidPlan();
    error InvalidExecution();
    event PlanApproved(uint64 indexed roundId, uint64 nonce, bytes32 hash);
    event FallbackActivated(uint64 indexed roundId);

    function create(uint64 roundId, uint256 total, uint16 aliveMask) external onlyHook {
        Budget storage b = self.rounds[roundId];
        if (b.deadline != 0 || aliveMask == 0 || (aliveMask & ~uint16(1023)) != 0) revert InvalidPlan();
        b.total = total;
        b.aliveMask = aliveMask;
        b.deadline = uint64(block.timestamp + 22 hours);
        _fallback(b);
        emit FallbackActivated(roundId);
    }

    function hash(BuybackPlan memory plan) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(block.chainid, hook, plan.roundId, plan.nonce, plan.deadline, plan.allocations)
            );
    }

    function approve(BuybackPlan calldata plan, address verifier, bytes calldata proof) external onlyHook {
        Budget storage b = self.rounds[plan.roundId];
        if (
            verifier == address(0) || b.authorizationPending || b.deadline == 0 || block.timestamp >= b.deadline
                || plan.deadline <= block.timestamp || plan.deadline > b.deadline || plan.nonce <= b.nonce
        ) revert InvalidPlan();
        uint256 n = _count(b.aliveMask);
        uint256 minimum = b.total * 3 / (4 * n);
        uint256 maximum = (b.total * 5 + 4 * n - 1) / (4 * n);
        uint256 sum;
        for (uint8 i; i < 10; ++i) {
            uint256 amount = plan.allocations[i];
            if ((b.aliveMask & (uint16(1) << i)) == 0) {
                if (amount != 0) revert InvalidPlan();
            } else if (amount < minimum || amount > maximum || amount < b.crewSpent[i]) {
                revert InvalidPlan();
            }
            sum += amount;
        }
        if (sum != b.total || !IMugiIMDBuybackPlanVerifier(verifier).verify(hash(plan), proof, hook)) {
            revert InvalidPlan();
        }
        b.allocation = plan.allocations;
        b.nonce = plan.nonce;
        b.planValidUntil = plan.deadline;
        emit PlanApproved(plan.roundId, plan.nonce, hash(plan));
    }

    function authorize(uint64 roundId, uint8 crew, uint256 amount) external onlyHook {
        Budget storage b = self.rounds[roundId];
        if (
            crew >= 10 || b.authorizationPending || b.deadline == 0 || block.timestamp >= b.deadline || amount == 0
                || (b.aliveMask & (uint16(1) << crew)) == 0
        ) revert InvalidExecution();
        if (block.timestamp > b.planValidUntil) {
            _fallback(b);
            emit FallbackActivated(roundId);
        }
        uint256 chunk = (b.total + 19) / 20;
        if (
            amount < _minimumTrade(b, crew) || amount > chunk
                || b.crewSpent[crew] + amount > b.allocation[crew] || b.spent + amount > b.total
                || (b.lastTrade[crew] != 0 && block.timestamp < b.lastTrade[crew] + 5 minutes)
        ) {
            revert InvalidExecution();
        }
        b.lastTrade[crew] = uint64(block.timestamp);
        b.authorizedAmount = amount;
        b.authorizedCrew = crew;
        b.authorizationPending = true;
    }

    function account(uint64 roundId, uint8 crew, uint256 actualSpent) external onlyHook {
        Budget storage b = self.rounds[roundId];
        if (
            !b.authorizationPending || crew != b.authorizedCrew || actualSpent < _minimumTrade(b, crew)
                || actualSpent > b.authorizedAmount
                || b.spent + actualSpent > b.total || b.crewSpent[crew] + actualSpent > b.allocation[crew]
        ) {
            revert InvalidExecution();
        }
        b.authorizationPending = false;
        b.authorizedAmount = 0;
        b.spent += actualSpent;
        b.crewSpent[crew] += actualSpent;
    }

    /// @dev Each successful trade makes meaningful progress before consuming its cadence slot.
    /// Permit a final remainder below 1% so an allocation can be exhausted exactly.
    function _minimumTrade(Budget storage b, uint8 crew) private view returns (uint256) {
        uint256 allocation = b.allocation[crew];
        uint256 minimum = allocation / 100;
        if (allocation % 100 != 0) ++minimum;
        uint256 remaining = allocation - b.crewSpent[crew];
        return minimum < remaining ? minimum : remaining;
    }

    function _fallback(Budget storage b) private {
        uint256 n = _count(b.aliveMask);
        uint256 equal = b.total / n;
        uint256 remainder = b.total % n;
        uint256 sum;
        for (uint8 i; i < 10; ++i) {
            if ((b.aliveMask & (uint16(1) << i)) == 0) continue;
            uint256 target = equal;
            if (remainder != 0) {
                ++target;
                --remainder;
            }
            if (target < b.crewSpent[i]) target = b.crewSpent[i];
            b.allocation[i] = target;
            sum += target;
        }
        uint256 excess = sum - b.total;
        uint256 minimum = b.total * 3 / (4 * n);
        for (uint8 i; i < 10 && excess != 0; ++i) {
            if ((b.aliveMask & (uint16(1) << i)) == 0) continue;
            uint256 floor = b.crewSpent[i] > minimum ? b.crewSpent[i] : minimum;
            uint256 room = b.allocation[i] - floor;
            uint256 reduction = room < excess ? room : excess;
            b.allocation[i] -= reduction;
            excess -= reduction;
        }
        if (excess != 0) revert InvalidPlan();
        b.planValidUntil = b.deadline;
    }

    function _count(uint16 mask) private pure returns (uint256 n) {
        for (uint8 i; i < 10; ++i) {
            if ((mask & (uint16(1) << i)) != 0) ++n;
        }
    }
}
