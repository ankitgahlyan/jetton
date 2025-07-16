import "@stdlib/ownable";
import "./jetton-wallet";

/// Message for upgrading contract code and data with a timeout.
message Upgrade {
    /// New code of the contract.
    /// Defaults to `null`, which keeps the previous code.
    code: Cell? = null;

    /// New data of the contract.
    /// Defaults to `null`, which keeps the previous data.
    data: Cell? = null;

    /// Delay in seconds before upgrade can be confirmed.
    /// Defaults to zero, which means the upgrade can be confirmed immediately.
    /// Unused in `Upgradable` trait.
    timeout: Int = 0;
}

/// Message for confirming delayed upgrade execution.
/// Must be sent after the timeout specified in the `Upgrade` message has elapsed.
/// Can only be processed by contracts that implement the `DelayedUpgradable` trait.
message Confirm {}

/// Extended version of `Upgradable` that adds a delay mechanism.
///
/// The upgrade process happens in two steps:
/// 1. Owner initiates an upgrade by sending the `Upgrade` message.
/// 2. After a timeout period, the owner confirms the upgrade by sending the `Confirm` message.
trait DelayedUpgradable with Upgradable {
    /// Contract owner address that can perform upgrades.
    owner: Address;

    /// Current contract version, auto-increments after each upgrade.
    /// Meant to be private and only accessible through the relevant getter.
    _version: Int as uint32;

    /// Timestamp in seconds of the last `Upgrade` message arrival.
    /// Used to enforce a timeout period before the confirmation.
    initiatedAt: Int;

    /// Contains new code, new data, and a timeout period.
    upgradeInfo: Upgrade;

    /// Confirms and executes a pending upgrade only after `upgradeInfo.timeout`
    /// seconds have passed since the last `_initiatedAt`.
    receive(msg: Confirm) {
        require(now() >= self.initiatedAt + self.upgradeInfo.timeout, "DelayedUpgradable: Cannot confirm upgrade before timeout");

        if (self.upgradeInfo.code != null) {
            // Change of code will be applied at the end of this transaction
            setCode(self.upgradeInfo.code!!);
        }
        if (self.upgradeInfo.data != null) {
            // Change of data will be immediate
            setData(self.upgradeInfo.data!!);

            // By the end of every transaction,
            // the Tact compiler automatically adds a call to setData() for your convenience.
            // However, we have already set the data ourselves,
            // so let us stop the execution now to prevent a secondary call to setData().
            throw(0);
        }
    }

    /// Instead of performing an upgrade right away,
    /// saves details for delayed execution.
    override inline fun upgrade(_: Context, msg: Upgrade) {
        self.upgradeInfo = msg;
        self.initiatedAt = now();
    }
}

//
// Helper traits and functions described earlier on this page
//

trait Upgradable with Ownable {
    owner: Address;
    _version: Int as uint32;

    receive(msg: Upgrade) {
        let ctx = context();
        self.validateUpgrade(ctx, msg);
        self.upgrade(ctx, msg);

        self._version += 1;
    }

    virtual inline fun validateUpgrade(_: Context, __: Upgrade) {
        self.requireOwner();
    }

    virtual inline fun upgrade(_: Context, msg: Upgrade) {
        if (msg.code != null) {
            setCode(msg.code!!);
        }
        if (msg.data != null) {
            setData(msg.data!!);
            throw(0);
        }
    }

    get fun isUpgradable(): Bool {
        return true;
    }

    get fun version(): Int {
        return self._version;
    }
}

asm fun setCode(code: Cell) { SETCODE }

fun emitEvent(eventType: Int, from: Address, to: Address, amount: Int) {
    emit(NetworkEvent{
        eventType: eventType,
        from: from,
        to: to,
        amount: amount
    }.toCell());
}

//
// Reference solution
//

message Vote {
    value: Bool;
}

message VoteConfirmed {
    value: Bool;
    voter: Address;
}

message DeployBallot {}

struct ProposalState {
    yesCount: Int as uint32;
    noCount: Int as uint32;
}

struct Init {
    proposalId: Int as uint32;
    votingEndingAt: Int as uint32;
}

contract Proposal {
    proposalId: Int as uint32;
    votingEndingAt: Int as uint32;

    yesCount: Int as uint32 = 0;
    totalCount: Int as uint32 = 0;

    init(data: Init) {
        self.proposalId = data.proposalId;
        self.votingEndingAt = data.votingEndingAt;
    }

    // deploy
    receive() {}

    receive(msg: Vote) {
        // Voting is already finished!
        throwUnless(701, now() < self.votingEndingAt);
        throwUnless(702, context().value > getComputeFee(31000, false));

        let ballot = initOf Ballot(
            sender(),
            myAddress(),
            false,
        );
        deploy(DeployParameters {
            mode: SendRemainingValue,
            value: 0,
            bounce: false,
            body: msg.toCell(),
            init: ballot,
        });
    }

    receive(msg: VoteConfirmed) {
        let ballot = initOf Ballot(
            msg.voter,
            myAddress(),
            false,
        );
        throwUnless(704, ballot.hasSameBasechainAddress(sender()));

        if (msg.value) {
            self.yesCount += 1;
        }

        self.totalCount += 1;

        cashback(msg.voter);
    }

    get fun proposalState(): ProposalState {
        return ProposalState {
            yesCount: self.yesCount,
            noCount: self.totalCount - self.yesCount,
        };
    }
}

contract Ballot(
    voter: Address,
    proposal: Address,
    hasVoted: Bool,
) {
    receive(msg: Vote) {
        if (self.hasVoted) {
            cashback(self.voter);
            return;
        }

        // Can only accept messages from the corresponding Proposal contract
        throwUnless(703, sender() == self.proposal);

        message(MessageParameters {
            to: self.proposal,
            mode: SendRemainingValue,
            value: 0,
            bounce: false,
            body: VoteConfirmed { value: msg.value, voter: self.voter }.toCell(),
        });

        self.hasVoted = true;
    }
}

//
// Reference solution
//

struct ProposalInit {
    master: Address;
    proposalId: Int as uint32;
}

message DeployNewProposal {
    votingEndingAt: Int as uint32;
}

message StartVoting {
    cashbackAddress: Address;
    votingEndingAt: Int as uint32;
}

contract ProposalMaster {
    const RESERVED_FUNDS: Int = ton("0.01");

    nextProposalId: Int as uint32 = 0;

    // top up
    receive() {
        nativeReserve(self.RESERVED_FUNDS, ReserveAtMost);
        cashbackBalance(sender());
    }

    receive(msg: DeployNewProposal) {
        require(msg.votingEndingAt >= now(), "Voting must end in the future");

        let proposalInit = initOf Proposal(ProposalInit {
            master: myAddress(),
            proposalId: self.nextProposalId,
        });

        deploy(DeployParameters {
            init: proposalInit,
            mode: SendRemainingValue,
            value: 0,
            body: StartVoting {
                cashbackAddress: sender(),
                votingEndingAt: msg.votingEndingAt,
            }.toCell(),
        });

        self.nextProposalId += 1;
    }

    get fun nextProposalId(): Int { return self.nextProposalId }
}

// ==============================================================================

message Vote {
    value: Bool;
}

struct ProposalState {
    yesCount: Int as uint32;
    noCount: Int as uint32;
    master: Address;
    proposalId: Int as uint32;
    votingEndingAt: Int as uint32;
}

contract Proposal {
    const INVALID_TIME: Int = 0;

    master: Address;
    proposalId: Int as uint32;

    votingEndingAt: Int as uint32;

    voters: map<Address, Bool> = emptyMap();
    yesCount: Int as uint7 = 0;
    totalCount: Int as uint7 = 0;

    init(data: ProposalInit) {
        throwUnless(2025, data.master == sender());
        self.proposalId = data.proposalId;
        self.master = data.master;
        self.votingEndingAt = self.INVALID_TIME;
    }

    receive(msg: StartVoting) {
        // init() is implicitly called here, so we know it is called by master
        // StartVoting can be called only once: it is guaranteed by the master contract
        require(self.votingEndingAt == self.INVALID_TIME, "Voting is already started");
        self.votingEndingAt = msg.votingEndingAt;

        cashbackBalance(msg.cashbackAddress);
    }

    receive(msg: Vote) {
        // There cannot be more than 100 voters
        throwUnless(700, self.totalCount < 100);
        // Voting is already finished!
        throwUnless(701, now() < self.votingEndingAt);
        let sender = sender();
        // User already voted
        throwUnless(702, !self.voters.exists(sender));

        self.voters.set(sender, true);

        if (msg.value) {
            self.yesCount += 1;
        }

        self.totalCount += 1;

        cashbackBalance(sender());
    }

    get fun proposalState(): ProposalState {
        return ProposalState {
            yesCount: self.yesCount,
            noCount: self.totalCount - self.yesCount,
            master: self.master,
            proposalId: self.proposalId,
            votingEndingAt: self.votingEndingAt,
        };
    }
}

asm fun cashbackBalance(to: Address) {
    // The following asm is equivalent to
    // ```tact
    // let msg: Cell = beginCell().storeInt(0b010000, 6).storeAddress(to).storeInt(0, 111).endCell();
    // nativeSendMessage(msg, SendRemainingBalance | SendIgnoreErrors);
    // ```
    // but is a bit more gas efficient
    16 PUSHINT       // 0x10, i.e. 0x18 but with bounce = false
    NEWC
    6 STU            // .storeUint(0x10, 6)
    STSLICE          // .storeAddress(to)
    0 PUSHINT        // 0
    111 STUR         // .storeUint(0, 111)
    // 4 zeros for coins and 107 zeros for lt, fees, etc.
    ENDC
    130 PUSHINT       // SendRemainingBalance | SendIgnoreErrors
    SENDRAWMSG
}