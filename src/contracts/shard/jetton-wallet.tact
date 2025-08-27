//  SPDX-License-Identifier: MIT
//  Copyright © 2025 TON Studio

import "./messages";
import "./constants";
import "./shard-utils";
import "./send";
import "../utils";

// TODO: implement traits ownableTransferable(to nominee) or internal update, delayedUpgradable
// TODO: p2p upgrades of walletCode + mbrpAmount etc using minter's signed payload
// call minter to update constants(mbrp) but only upwards is possible
//TODO: api to change invitor when/where fees goes for public works
//TODO: change gas co n sts
//if self.version != versionFromSender throw updateVersion
//TODO: inactivate/freeze chain on receive from invitor then send to all invited
//both sides checks can prevent bounced(foreach) side effects at cost of confusion
//map for bounced codes
//TODO: simplify by txn fee as emi/tax/insurance then burn for nonExistent/dead accs
/* FEATURES
both gets mbrp on invitation, 2times on friend, otherwise followed gets mbrp
unInvite for control, just freeze uninvited's invited not wholeChain cozOfBouncedConstraints

*/
// ERROR_CODES ===============================================================================================================
//700 ERR_INCORRECT_SENDER
const INCORRECT_SENDER: Int = 700;
const ACCOUNT_TERMINATED: Int = 701;
const ACCOUNT_INACTIVE: Int = 702;
const ACCOUNT_FROZEN: Int = 722;
const INSUFFICIENT_TON: Int = 703;
const RESERVED_INTERNAL: Int = 704;
const FOLLOW_INSTEAD: Int = 705;
const NO_PENDING_REQUEST: Int = 706;
const CANT_UNFOLLOW_REPORTED: Int = 707;
const SELF_DISPUTE_NOT_ALLOWED: Int = 708;
const INSUFFICIENT_BALANCE: Int = 709;
const ALREADY_REPORTED: Int = 710;
const ACCOUNT_NOT_REPORTED: Int = 711;
const NOT_AUTHORIZED: Int = 712;
//const LESS_THAN_1_TOKEN: Int = 713;
const INVITE_FIRST: Int = 714;
const AMOUNT_EXCEEDS_MBRP: Int = 715;
const ALREADY_FRIEND_OR_FOLLOWING: Int = 716;
const NOT_FOLLOWING: Int = 717;
const DOES_NOT_EXIST: Int = 718; //follower Cleared by confirmRequestInternal bounce
const CONNECTION_EXISTS: Int = 719;
const NOT_FRIEND: Int = 720;
const NOT_INVITOR: Int = 721;
const ALREADY_INVITED: Int = 723;

// CONTRACT_CONSTS ===========================================================================================================
const MAX_CONNECTIONS: Int = 250; //coz of msg sending constraints during accClosing
//const PAYLOAD: Slice = "empty".toSlice();

contract JettonWalletSharded {
    //STOP incoming tokens txn after transferredTo nominee
    //id token: signed payload by master
    // CONTRACT_PERSISTENT_STORE =============================================================================================
    owner: Address;
    minter: Address; //map for multiple peer contracts, treat as treasury + sudo(unbacked minting & force transfer like in governance), use dao address
    minterOwner: Address; //TODO: REMOVE
    balance: Int as coins = ton("1");
    nominee: Address?;
    invitor: Address?; //guarantor/offchain-contact responsible for kyc + education + proposal, propagator,TODO: nominee is appointed for all invited after it's demise; inactive account if null(no ops allowed perhaps)
    invited: map<Address, Int as uint12>; //TODO: need counter/check?or default exitCode5isEnough
    friends: map<Address, Int as uint12>; //if following followsBack or follower is followedBack then add here and remove there for saving time/compute & space/storage
    pendingRequests: map<Address, Int as uint12>;
    followers: map<Address, Int as uint12>;
    followings: map<Address, Int as uint12>; //4096 TODO: use max 255 coz of !storage/msg constraints
    debts: map<Address, Int as uint20>; //1,048,576, mbrp*maxConnections(friends+follower+following)
    reports: map<Address, Bool>; //TODO: consider reporter side data store then support and dispute there for less txns,tradeoff -> only one report at aTime
    reportReason: Bool = false; // true for genuineClosingOnDeath, false for fraud/duplicateIdsAccounts
    reporterCount: Int as uint10 = 0; //TODO: delegate2dao/admin handles out of range complaints
    disputerCount: Int as uint10 = 0; //1024
    reportResolutionTime: Int as uint32 = 0; //4,294,967,296
    connections: Int as uint8 = 0; //256
    terminated: Bool = false;
    //bloacklist: map<Address, Int as uint8>;//blocklist+blacklist
    //adminOps
    // Dynamically adjustable configuration parameters
    mbrpAmount: Int as coins = ton("1000");
    closureWait: Int as uint32 = 86400;
    frozen: Bool = false;
    //stores coz of chain/design constraints
    lastMsgTo: Address?; //for reversing bounced msg
    // lastFollower: Address?; //for reversing bounced msg
    // lastFollowing: Address?;
    // lastFriend: Address?;
    // lastInvite: Address?;

    //======================================================INIT==============================================================
    init(owner: Address, minter: Address, minterOwner: Address) { //TODO: take coordinates
        self.owner = owner;
        self.minter = minter;
        self.minterOwner = minterOwner;
        //notify TODO: or on invite
    }

    //====================================================RECEIVERS===========================================================
    receive(msg: JettonTransfer) {
        let sender = sender(); //TODO: Check whole callChain if var is used? thrice?
        let receiver = msg.destination;
        let amount = msg.amount;
        let mbrp = self.mbrpAmount;
        let body = JettonTransferInternal {
            queryId: msg.queryId,
            amount,
            sender,
            responseDestination: msg.responseDestination,
            forwardTonAmount: msg.forwardTonAmount,
            forwardPayload: msg.forwardPayload,
        }.toCell();

        throwUnless(INCORRECT_SENDER, sender == self.owner);
        throwUnless(ACCOUNT_TERMINATED, !self.terminated); //rootCanRestoreJustInCase
        throwUnless(ACCOUNT_INACTIVE, self.invitor != null); // || sender == self.minterOwner); //TODO:
        throwUnless(ACCOUNT_FROZEN, !self.frozen);
        forceBasechain(receiver);

        checkEitherForwardPayload(msg.forwardPayload);

        let ctx = context();
        let fwdCount = 1 + sign(msg.forwardTonAmount); // msg.forwardTonAmount is coins, so it's positive
        throwUnless(
            INSUFFICIENT_TON,
            ctx.value >
            msg.forwardTonAmount +
            fwdCount * ctx.readForwardFee() +
            getForwardFee(walletStateInitCells, walletStateInitBits, false) +
            (2 * getComputeFee(gasForTransfer, false) + minTonsForStorage),
        );
        //self.checks(sender, receiver);

        if (amount < ton("1")) {
            if (amount == ton("0.1")) { //invite
                self.invite(receiver, mbrp);
                body = InviteInternal {
                    queryId: msg.queryId, //FIXME: queryId passing with care
                    amount: mbrp,
                    sender: self.owner,
                    responseDestination: msg.responseDestination,
                    forwardTonAmount: msg.forwardTonAmount,
                    forwardPayload: msg.forwardPayload,
                }.toCell();
            } else if (amount == ton("0.2")) { //send friendRequest
                self.friendRequest(2 * mbrp, msg);
                return;
            } else if (amount == ton("0.3")) {
                self.confirmFRequest(receiver, msg);
                return;
            } else if (amount == ton("0.3")) {
                self.unfriend(receiver, msg);
                return;
            } else if (amount == ton("0.6")) { // 0.2 token - report tosViolate
                self.report(sender, receiver, mbrp, false, msg); //redundant?TODO:
                return;
            } else if (amount == ton("0.7")) { // 0.5 token - report onDeath
                self.report(sender, receiver, mbrp, true, msg);
                return;
            } else if (amount == ton("0.8")) { // 0.3 token - dispute
                self.dispute(sender, mbrp, receiver, msg);
                return;
            } else if (amount == ton("0.9")) { // 0.4 token - process report
                self.reportResolution(receiver, msg);
                return;
            } else if (amount == ton("0.4")) { // 0.4 token - process report
                self.nominee = receiver;
                //self.changeNominee(receiver);
                return; //maybe notify msg.destination
            } else if (amount == ton("0.5")) { // 0.1 token - invite/follow/unfollow
                self.follow(receiver, mbrp, msg); //TODO: location params from custom payload forwardPayload
                return;
            } else if (amount == ton("0.12")) {
                self.unfollow(receiver, mbrp, msg);
                return;
            } else if (amount == ton("0.11")) { //clean requests to free contract storage
                self.clearAllRequests();
                return;
            } else if (amount == ton("0.13")) { //clean requests to free contract storage
                self.unInvite(receiver, msg);
                return;
            } else if (amount == ton("0.02")) { // reserved for invite
                throwUnless(RESERVED_INTERNAL, false); //invite(mbrp),burn, reward(2x mbrp)
            } // else if (amount == ton("0.21")) { // getterOps
            //     let invitorNominee = self.get_invitor_nominee();//FIXME:
            //     self.getterCall(invitorNominee);
            //     return;
            // } else if (sender == self.minter) { // Admin operations (owner only)
            //     self.adminAction(msg);
            // }
        } else {
            self.transfer(amount);
        } // Standard transfer
        DeployParameters {
            value: 0,
            mode: SendRemainingValue,
            body,
            init: self.getInit(receiver),
        }.toShard(receiver.getShard()).send();
    }

    receive(msg: JettonTransferInternal) {
        let sender = msg.sender;
        let senderC = sender();
        let amount = msg.amount;
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;

        // if (amount == ton("0.02")) { }
        self.checkInternal(sender, amount, null, queryId, forwardTonAmount, forwardPayload, responseDestination);

        if (senderC == self.minter && amount == ton("0.1")) { //TODO: use for other rootOps
            self.inviteInternal(senderC, 0);
            return;
        }
        self.mintInternal(amount);
    }

    //====================================================INTERNAL_FUNCTIONS==================================================
    inline fun invite(receiver: Address, amount: Int) {
        self.connection(receiver);
        //self.friends.set(receiver, amount);
        self.invited.set(receiver, amount);
        self.lastMsgTo = receiver;
        self.connections += 1;
        self.mintInternal(amount);
    }

    bounced(msg: bounced<InviteInternal>) {
        let _ = self.invited.del(self.lastMsgTo!!);
        self.connections -= 1;
        //self.lastMsgTo = null;
        self.balance -= msg.amount; //FIXME: safe? can other txn race? 
        //self.burnInternal(self.lastMsgTo!!, msg.amount); //2x mbrp//bounce debtBurnToMinter
    }

    receive(msg: InviteInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, true, queryId, forwardTonAmount, forwardPayload, responseDestination);

        self.inviteInternal(msg.sender, msg.amount);
    }

    inline fun inviteInternal(sender: Address, amount: Int) {
        throwUnless(ALREADY_INVITED, self.invitor == null || self.frozen);
        self.invitor = sender;
        self.nominee = sender;

        self.mintInternal(amount);
        self.frozen = false;
        //self.frozen ? false : false;
        //self.lastMsgTo = sender;//used for bounced
        // if (self.frozen) {//recursion
        //     foreach (invitee, amount in self.invited) {
        //         MessageParameters {//TODO: fees paid by receivers
        //             to: contractAddress(self.getInit(invitee)),
        //             value: 0,
        //             mode: SendRemainingValue | SendBounceIfActionFail,
        //             body: ReInviteInternal {
        //                 queryId: msg.queryId,
        //                 amount,//FIXME: internal?
        //                 sender: self.owner,
        //                 responseDestination: msg.responseDestination,
        //                 forwardTonAmount: msg.forwardTonAmount,
        //                 forwardPayload: msg.forwardPayload,
        //             }.toCell(),

        //         }.send();
        //     }
        // }
    }

    // receive(msg: ReInviteInternal) {//for chain Unfreeze
    //      let queryId = msg.queryId;
    //     let forwardTonAmount = msg.forwardTonAmount;
    //     let forwardPayload = msg.forwardPayload;
    //     let responseDestination = msg.responseDestination;
    //     self.checkInternal(msg.sender, msg.amount, null, queryId, forwardTonAmount, forwardPayload, responseDestination);

    //     throwUnless(NOT_INVITOR, self.invitor!! == msg.sender);
    //     self.invitor = msg.sender;
    //     self.frozen = false;
    // }

    // bounced(msg: bounced<ReInviteInternal>) {//FIXME:
    //     let _ = self.invited.del(self.lastMsgTo!!);
    //     self.burnInternal(self.lastMsgTo!!, msg.amount);
    // }

    inline fun unInvite(receiver: Address, msg: JettonTransfer) {
        throwUnless(NOT_INVITOR, self.invited.del(receiver));
        let amount = self.invited.get(receiver)!!;
        self.burnInternal(receiver, amount);

        MessageParameters { //TODO: fees paid by receivers
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: UnInviteInternal {
                queryId: msg.queryId,
                amount, //FIXME: internal?
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();

        self.lastMsgTo = receiver;
        self.connections -= 1;
    }

    bounced(msg: bounced<UnInviteInternal>) {
        self.invited.set(self.lastMsgTo!!, msg.amount);
        //self.mintInternal(msg.amount);
        self.balance += msg.amount;
        self.connections += 1;
    }

    receive(msg: UnInviteInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, false, queryId, forwardTonAmount, forwardPayload, responseDestination);

        throwUnless(NOT_INVITOR, self.invitor == msg.sender); //redundant bothSide check for unBounced s
        self.frozen = true;
        //maybe no burns if coz someone will reinvite eventually, don't mint THEN
        self.burnInternal(msg.sender, msg.amount);
    }

    inline fun friendRequest(amount: Int, msg: JettonTransfer) {
        self.connection(msg.destination);
        //throwUnless(AMOUNT_EXCEEDS_MBRP, msg.amount <= self.mbrpAmount);//TODO:
        MessageParameters {
            to: contractAddress(self.getInit(msg.destination)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: FriendRequestInternal {
                queryId: msg.queryId,
                amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();
    }

    receive(msg: FriendRequestInternal) {
        throwUnless(INVITE_FIRST, self.invitor != null);
        throwUnless(MAX_CONNECTIONS, self.connections < MAX_CONNECTIONS);

        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, null, queryId, forwardTonAmount, forwardPayload, responseDestination);

        self.pendingRequests.set(msg.sender, msg.amount);
    }

    inline fun confirmFRequest(receiver: Address, msg: JettonTransfer) {
        throwUnless(NO_PENDING_REQUEST, self.pendingRequests.exists(receiver));

        let amount = self.pendingRequests.get(receiver)!!;
        self.mintInternal(amount);

        self.friends.set(receiver, amount);

        MessageParameters {
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: ConfirmRequestInternal {
                queryId: msg.queryId,
                amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();

        self.lastMsgTo = receiver;
        let _ = self.pendingRequests.del(receiver);
        self.connections += 1;
    }

    bounced(msg: bounced<ConfirmRequestInternal>) {
        let last = self.lastMsgTo!!;
        let _ = self.friends.del(last);
        self.balance -= msg.amount;
        //self.burnInternal(last, msg.amount); //FIXME: whatIf was in followers?update otherSide following

        self.pendingRequests.set(last, msg.amount);
        self.connections -= 1;
    }

    receive(msg: ConfirmRequestInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, true, queryId, forwardTonAmount, forwardPayload, responseDestination);

        self.mintInternal(msg.amount);
        self.friends.set(msg.sender, msg.amount);
        self.connections += 1;
    }

    inline fun unfriend(receiver: Address, msg: JettonTransfer) {
        throwUnless(NOT_FRIEND, self.friends.exists(receiver));
        let amount = self.friends.get(receiver)!!;
        let _ = self.friends.del(receiver);
        self.burnInternal(receiver, amount);

        MessageParameters {
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: UnfriendInternal {
                queryId: msg.queryId,
                amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();

        self.lastMsgTo = receiver;
        self.connections -= 1;
    }

    bounced(msg: bounced<UnfriendInternal>) {
        let last = self.lastMsgTo!!;
        self.friends.set(last, msg.amount);
        //self.mintInternal(msg.amount);
        self.balance += msg.amount;
        self.connections += 1;
    }

    receive(msg: UnfriendInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, false, queryId, forwardTonAmount, forwardPayload, responseDestination);

        let _ = self.friends.del(msg.sender);
        self.burnInternal(msg.sender, msg.amount);
    }

    inline fun clearAllRequests() {
        if (!self.pendingRequests.isEmpty()) {
            self.pendingRequests = null; //emptyMap();
        }
        emit("clearedPendingRequests".asComment()); //TODO: handle events
    }

    inline fun follow(receiver: Address, amount: Int, msg: JettonTransfer) {
        self.connection(receiver);

        self.followings.set(receiver, amount);

        MessageParameters {
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: FollowInternal {
                queryId: msg.queryId,
                amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();

        self.lastMsgTo = receiver;
        self.connections += 1;
    }

    bounced(msg: bounced<FollowInternal>) {
        let _ = self.followings.del(self.lastMsgTo!!);
        self.connections -= 1;
    }

    receive(msg: FollowInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, true, queryId, forwardTonAmount, forwardPayload, responseDestination);

        throwUnless(INVITE_FIRST, self.invitor != null);
        throwUnless(MAX_CONNECTIONS, self.connections < MAX_CONNECTIONS);

        self.balance += self.mbrpAmount;

        self.followers.set(msg.sender, self.mbrpAmount);
        self.connections += 1;

        //TODO: tells follower's followers about this follow or invite and add to network
        //emitEvent(1, msg.sender, self.owner, msg.amount);
    }

    inline fun unfollow(receiver: Address, amount: Int, msg: JettonTransfer) {
        //throwUnless(NOT_FOLLOWING, self.followings.exists(receiver));
        throwUnless(NOT_FOLLOWING, self.followings.del(receiver)); //OPTIMISTIC

        MessageParameters {
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: UnfollowInternal {
                queryId: msg.queryId,
                amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();

        self.lastMsgTo = receiver;
        self.connections -= 1;
    }

    bounced(msg: bounced<UnfollowInternal>) {
        self.followings.set(self.lastMsgTo!!, msg.amount);
        self.connections += 1;
    }

    receive(msg: UnfollowInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, false, queryId, forwardTonAmount, forwardPayload, responseDestination);

        self.unfollowInternal(msg.sender, msg.amount);
    }

    inline fun unfollowInternal(sender: Address, amount: Int) {
        throwUnless(CANT_UNFOLLOW_REPORTED, self.reporterCount == 0);

        let _ = self.followers.del(sender);

        if (self.connections > 0) {
            self.connections -= 1;
        }

        self.burnInternal(sender, amount);
    }

    inline fun report(sender: Address, receiver: Address, amount: Int, reason: Bool, msg: JettonTransfer) {
        //require receiver is from same contract
        //require(receiver != self.owner || myAddress(), "Cannot report self");//programmedInHumans
        throwUnless(SELF_DISPUTE_NOT_ALLOWED, receiver != self.minter);
        // if (receiver == self.minter) {//govtWay of discouraging smartAsses/badBehavior(stick over carrot)
        //     self.balance -= self.balance;
        //     require(false, "uROfficiallyFuckedBro!");
        // }
        self.balance -= self.mbrpAmount;
        throwUnless(INSUFFICIENT_BALANCE, self.balance >= 0);
        MessageParameters {
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: ReportInternal {
                queryId: msg.queryId,
                amount,
                reason,
                sender,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();

        //self.lastMsgTo = receiver;
    }

    bounced(msg: bounced<ReportInternal>) { self.balance += msg.amount }

    receive(msg: ReportInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, null, queryId, forwardTonAmount, forwardPayload, responseDestination);
        self.reportInternal(msg.sender, msg.reason, msg);
    }

    inline fun reportInternal(sender: Address, reason: Bool, msg: ReportInternal) {
        //TODO: invitor auto disputes or noNeed (consider disputed implicitly)
        if (reason) {
            self.reportReason = reason;
        } //false byDefault//TODO: reason complete?
        throwUnless(ACCOUNT_INACTIVE, self.invitor != null);
        throwUnless(ALREADY_REPORTED, !self.reports.exists(sender));
        self.reports.set(sender, true);
        self.reporterCount += 1;
        self.reportResolutionTime = now() + self.closureWait; //TODO: INC time onlyIf this overtakes others(disputers)

        let receiver = self.invitor!!; // null sentinel handled by require above
        let walletInit = self.getInit(receiver);
        //let receiverAddr = contractShardBasechainAddress(walletInit);
        //burn/stake from receiver's invitor once in case of duplicateId only
        if (reason && self.reports == null) {
            DeployParameters {
                value: 0,
                mode: SendRemainingValue,
                body: JettonTransferInternal {
                    queryId: msg.queryId,
                    amount: ton("0.02"),
                    sender: self.owner,
                    responseDestination: msg.responseDestination, //TODO: need2change?
                    forwardTonAmount: msg.forwardTonAmount,
                    forwardPayload: msg.forwardPayload,
                }.toCell(),
                init: walletInit,
            }.toShard(receiver.getShard()).send();
        }
    }

    inline fun dispute(sender: Address, amount: Int, receiver: Address, msg: JettonTransfer) {
        //stake
        throwUnless(SELF_DISPUTE_NOT_ALLOWED, receiver != self.minter);
        throwUnless(SELF_DISPUTE_NOT_ALLOWED, sender != receiver);
        self.balance -= amount;
        throwUnless(INSUFFICIENT_BALANCE, self.balance >= 0);

        MessageParameters {
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            mode: SendRemainingValue | SendBounceIfActionFail,
            body: DisputeInternal {
                queryId: msg.queryId,
                amount,
                sender,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();
    }

    bounced(msg: bounced<DisputeInternal>) { self.balance += msg.amount }

    receive(msg: DisputeInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, null, queryId, forwardTonAmount, forwardPayload, responseDestination);

        self.disputeInternal(msg.sender);
    }

    inline fun disputeInternal(sender: Address) {
        throwUnless(ACCOUNT_NOT_REPORTED, self.reporterCount > 0);
        self.reports.set(sender, false);
        self.disputerCount += 1;
        self.reportResolutionTime = now() + self.closureWait;
    }

    inline fun reportResolution(receiver: Address, msg: JettonTransfer) {
        MessageParameters {
            to: contractAddress(self.getInit(receiver)),
            value: 0,
            bounce: false,
            mode: SendRemainingValue | SendBounceIfActionFail, //FIXME
            body: ResolutionInternal {
                queryId: msg.queryId,
                amount: msg.amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),

        }.send();
    }

    receive(msg: ResolutionInternal) {
        let queryId = msg.queryId;
        let forwardTonAmount = msg.forwardTonAmount;
        let forwardPayload = msg.forwardPayload;
        let responseDestination = msg.responseDestination;
        self.checkInternal(msg.sender, msg.amount, null, queryId, forwardTonAmount, forwardPayload, responseDestination);

        self.reportResolutionInternal(msg);
    }

    inline fun reportResolutionInternal(msg: ResolutionInternal) {
        throwUnless(NO_PENDING_REQUEST, self.reportResolutionTime > 0); //notOptional it's semantic otherwise need null
        throwUnless(INSUFFICIENT_TON, now() >= self.reportResolutionTime);

        let reporters = self.reporterCount;
        let disputers = self.disputerCount;
        let mbrp = self.mbrpAmount;

        // decide winner
        // reporters should be more than disputers no ties allowed
        let reportWinCloseAcc: Bool = reporters > disputers; //>= IF invitor NOT disputes byDefault 

        // reward winners 2x mbrp(stake+reward), losers lose stake
        let losersCount: Int = 0;
        if (reportWinCloseAcc) {
            losersCount = disputers;
        } else {
            losersCount = reporters;
        }
        let rewarded: Int = 0;

        // Distribute rewards: first `losersCount` winners get 2x, remaining winners get 1x.
        // Remove entries as we process them so the following foreach (below) becomes a no-op.
        foreach (addr, reporter in self.reports) { //TODO: can send only around 250 msg(maybe keep count & send last msg to self to process remaining txns.),forNow maxConn are 200
            // determine if this entry is a winner
            if ((reporter && reportWinCloseAcc) || (!reporter && !reportWinCloseAcc)) {
                let reward: Int = 0;
                if (rewarded < losersCount) {
                    reward = 2 * mbrp; // 2x mbrp
                    rewarded += 1;
                } else {
                    reward = mbrp; // release stake (1x mbrp)
                }

                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0, //FIXME:
                        amount: reward,
                        sender: self.owner,
                        responseDestination: self.owner,
                        forwardTonAmount: 0,
                        forwardPayload: msg.forwardPayload,
                    }.toCell(),
                }.send();
            }

            // remove the processed report entry
            let _ = self.reports.del(addr);
        }

        if (reportWinCloseAcc) { //TODO; REASON MATTERS?
            // Unfollow all and burn from followers/followings/friends.
            // If address is in friends -> treat as both in followings and followers

            // First iterate followings
            foreach (addr, amount in self.followings) {
                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: AccCloseBurnInternal {
                        queryId: msg.queryId,
                        amount,
                        sender: self.owner,
                        responseDestination: msg.responseDestination,
                        forwardPayload: msg.forwardPayload,
                        forwardTonAmount: msg.forwardTonAmount,
                    }.toCell(),
                }.send();

                // if (self.connections > 0) {
                //     self.connections -= 1;
                // }
                // let _ = self.followings.del(addr);
            }

            // Now handle remaining followers
            foreach (addr, amount in self.followers) {
                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: AccCloseBurnInternal {
                        queryId: msg.queryId,
                        amount,
                        sender: self.owner,
                        responseDestination: msg.responseDestination,
                        forwardPayload: msg.forwardPayload,
                        forwardTonAmount: msg.forwardTonAmount,
                    }.toCell(),
                }.send();

                //let _ = self.followers.del(addr);
            }

            // Now handle remaining followers
            foreach (addr, amount in self.friends) {
                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: AccCloseBurnInternal {
                        queryId: msg.queryId,
                        amount, //2x mbrp
                        sender: self.owner,
                        responseDestination: msg.responseDestination,
                        forwardPayload: msg.forwardPayload,
                        forwardTonAmount: msg.forwardTonAmount,
                    }.toCell(),
                }.send();
                //let _ = self.friends.del(addr);
            }
            foreach (addr, amount in self.invited) {
                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: AccCloseBurnInternal { //TODO: mark frozen/inactive
                        queryId: msg.queryId,
                        amount: 2 * amount, //2x mbrp
                        sender: self.owner,
                        responseDestination: msg.responseDestination,
                        forwardPayload: msg.forwardPayload,
                        forwardTonAmount: msg.forwardTonAmount,
                    }.toCell(),
                }.send();
                //invitor burn TODO:
            }
            self.terminated = true;
        } else {
            // reset report-related state
            self.reportResolutionTime = 0;
            self.reporterCount = 0;
            self.disputerCount = 0;
            self.reportReason = false;
        }
    }

    receive(msg: AccCloseBurnInternal) {
        self.burnInternal(msg.sender, msg.amount);
        //FIXME:
    }

    bounced(msg: bounced<AccCloseBurnInternal>) {
        //notify treasury
    }

    inline fun transfer(amount: Int) {
        //TODO: if (self.balance < 0) {adjust debts}//consider using debts only instead of -veBalance
        self.balance -= amount;
        throwUnless(INSUFFICIENT_BALANCE, self.balance >= 0);
    }

    inline fun mintInternal(amount: Int) { //TODO: adjust this logic in receiver maybe
        //ton("0.02")) { //from internalReport invitor burn

        amount = self._deductDebt(amount);
        self.balance += amount;
    }

    // fun changeNominee(nominee: Address) {//small logic, so adjusted in receiver
    //     self.nominee = nominee;
    // }
    inline fun adminAction(msg: JettonTransfer) {}

    inline fun adminActionInternal(msg: JettonTransferInternal) {}

    receive(msg: ProvideWalletBalance) {
        throwUnless(ACCOUNT_TERMINATED, !self.terminated);
        let info: VerifyInfo? = null;
        if (msg.includeVerifyInfo) {
            info = VerifyInfo {
                minter: self.minter,
                owner: self.owner,
                code: myCode(),
            };
        }

        MessageParameters {
            body: TakeWalletBalance {
                balance: self.balance,
                verifyInfo: info,
            }.toCell(),
            to: msg.receiver,
            value: 0,
            mode: SendRemainingValue,
        }.send();
    }

    receive(msg: JettonBurn) {
        throwUnless(ACCOUNT_TERMINATED, !self.terminated);
        // we can skip forceBasechain here because with other checks in place it's not possible
        // to acquire jettons outside of basechain, so amount check is enough
        throwUnless(INCORRECT_SENDER, sender() == self.owner);

        self.balance -= msg.amount;
        throwUnless(INSUFFICIENT_BALANCE, self.balance >= 0);

        let ctx = context();
        let fwdFee: Int = ctx.readForwardFee();
        throwUnless(INSUFFICIENT_TON, ctx.value > (fwdFee + 2 * getComputeFee(gasForBurn, false)));

        MessageParameters {
            to: self.minter,
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: JettonBurnNotification {
                queryId: msg.queryId,
                amount: msg.amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
            }.toCell(),
        }.send();
    }

    receive(msg: ClaimTON) {
        throwUnless(ACCOUNT_TERMINATED, !self.terminated);
        throwUnless(INCORRECT_SENDER, sender() == self.owner);
        nativeReserve(minTonsForStorage, ReserveExact | ReserveBounceIfActionFail);

        // we allow bounce here and don't handle it, if claim fails we just accept the TONs back
        MessageParameters {
            to: msg.receiver,
            value: 0,
            mode: SendRemainingBalance,
        }.send();
    }

    // receive("updateMBRP") {
    //     throwUnless(ACCOUNT_TERMINATED, !self.terminated);
    //     //TODO: v2
    // }

    bounced(msg: bounced<JettonTransferInternal>) {
        self.balance += msg.amount;
    }

    bounced(msg: bounced<JettonBurnNotification>) {
        //TODO: send again

        self.balance += msg.amount;
    }

    // helpers
    // fun checks(sender: Address, receiver: Address) {
    //     throwUnless(INCORRECT_SENDER, sender == self.owner);
    //     throwUnless(ACCOUNT_TERMINATED, !self.terminated);//rootCanRestoreJustInCase
    //     throwUnless(ACCOUNT_INACTIVE, self.invitor != null || self.owner == self.minterOwner);//TODO:
    //     forceBasechain(receiver);

    //     checkEitherForwardPayload(msg.forwardPayload);

    //     let ctx = context();
    //     let fwdCount = 1 + sign(msg.forwardTonAmount); // msg.forwardTonAmount is coins, so it's positive
    //     throwUnless(
    //         INSUFFICIENT_TON,
    //         ctx.value >
    //         msg.forwardTonAmount +
    //         fwdCount * ctx.readForwardFee() +
    //         getForwardFee(walletStateInitCells, walletStateInitBits, false) +
    //         (2 * getComputeFee(gasForTransfer, false) + minTonsForStorage)
    //     );
    // }

    fun connection(receiver: Address) {
        throwUnless(MAX_CONNECTIONS, self.connections < MAX_CONNECTIONS);
        throwUnless(
            CONNECTION_EXISTS,
            !self.friends.exists(receiver) && !self.followings.exists(receiver) && !self.invited.exists(receiver) && self.invitor != receiver && !self.followers.exists(receiver),
        ); //ACCOUNT EXISTS
    }

    fun checkInternal(sender: Address, amount: Int, mint: Bool?, queryId: Int, forwardTonAmount: Int, forwardPayload: Slice, responseDestination: Address?) {
        let senderC = sender();

        throwUnless(ACCOUNT_TERMINATED, !self.terminated); //deadPersonsAccounts or duplicateClosedAccs
        // This message should come only from other JettonWallet or minter/sudo
        let wallet: StateInit = self.getInit(sender);
        if (!(wallet.hasSameBasechainAddressWithoutShard(senderC))) {
            //TODO: master can't mint so remove and return
            throwUnless(INCORRECT_SENDER, self.minter == sender());
        }

        //throwUnless(LESS_THAN_1_TOKEN, amount >= ton("1"));

        // if (msg::op != InviteInternal) {
        //     throwUnless(ACCOUNT_INACTIVE, self.invitor != null);//noIncomingTxns.
        // }

        let ctx: Context = context();
        let msgValue: Int = ctx.value;
        let tonBalanceBeforeMsg = myBalance() - msgValue;

        if (forwardTonAmount > 0) {
            let fwdFee: Int = ctx.readForwardFee();
            msgValue -= forwardTonAmount + fwdFee;
            MessageParameters {
                to: self.owner,
                value: forwardTonAmount,
                mode: SendPayGasSeparately,
                bounce: false,
                body: JettonNotification { // 0x7362d09c -- Remind the new Owner
                    queryId,
                    amount,
                    sender,
                    forwardPayload,
                }.toCell(),
            }.send();

            if (mint != null) {
                let finalSender = sender;
                if (mint!!) {
                    finalSender = self.minterOwner; //use emptyAddress()
                }

                MessageParameters { //TODO: FIXME: MAYBE -VE IN MINT +VE ON BURN
                    to: self.minter,
                    value: 0,
                    mode: SendPayGasSeparately,
                    bounce: false,
                    body: JettonBurnNotification { //JettonMintBurnNotify maybe traitViolationOccursThen
                        queryId,
                        amount,
                        sender: finalSender, //use this for mint or burn identifier TODO:
                        responseDestination,
                    }.toCell(),
                }.send();
            }
        }
        nativeReserve(max(tonBalanceBeforeMsg, minTonsForStorage), ReserveAtMost);
        // 0xd53276db -- Cashback to the original Sender
        if (responseDestination != null && msgValue > 0) {
            MessageParameters {
                to: responseDestination!!,
                value: msgValue,
                mode: SendRemainingBalance | SendIgnoreErrors,
                bounce: false,
                body: JettonExcesses { queryId }.toCell(),
            }.send();
        }
    }

    inline fun _deductDebt(amount: Int): Int {
        let remaining: Int = amount;
        // nothing to do
        if (remaining <= 0 || self.debts.isEmpty()) {
            return remaining;
        }

        // Pay debts in map order until remaining is exhausted
        foreach (follower, debtVal in self.debts) {
            if (remaining <= 0) {
                return 0; //return remaining;TODO:
            }

            let debt: Int = debtVal;
            let pay = 0;
            if (remaining >= debt) {
                pay = debt;
            } else {
                pay = remaining;
            }
            debt -= pay;
            remaining -= pay;

            if (debt == 0) {
                let _ = self.debts.del(follower);
            } else {
                self.debts.set(follower, debt);
            }

            // optional: emit an event for debt payment
            // emitEvent(2, self.owner, follower, pay);
        }

        return remaining;
    }

    inline fun burnInternal(sender: Address, amount: Int) {
        if (amount <= 0) {
            return;
        }

        if (self.balance >= amount) {
            self.balance -= amount;
            return;
        }

        // Not enough balance — consume what is left and record remaining as debt to minter
        let shortfall: Int = amount - self.balance;
        self.balance = 0;

        let prevDebt: Int = 0; // TODO: need this? 
        if (self.debts.exists(sender)) {
            prevDebt = self.debts.get(sender)!!;
        }
        self.debts.set(self.minter, prevDebt + shortfall);
    }

    // inline fun getterCall(body: ) {
    //     MessageParameters {
    //         value: 0,
    //         to: sender(),
    //         bounce: false,
    //         body: body.toCell()
    //     }.send();
    // }

    get fun get_wallet_data(): JettonWalletData {
        throwUnless(ACCOUNT_TERMINATED, !self.terminated);
        return JettonWalletData {
            balance: self.balance,
            owner: self.owner,
            minter: self.minter,
            code: myCode(),
        };
    }

    get fun get_invitor_nominee(): InvitorNominee {
        return InvitorNominee {
            invitor: self.invitor,
            nominee: self.nominee,
        };
    }

    get fun get_friends_and_followings(): FriendsAndFollowings {
        throwUnless(ACCOUNT_TERMINATED, !self.terminated);
        throwUnless(NOT_AUTHORIZED, self.friends.exists(sender()) || self.followers.exists(sender()));
        return FriendsAndFollowings {
            friends: self.friends,
            followings: self.followings,
        };
    }

    fun getInit(address: Address): StateInit {
        return initOf JettonWalletSharded(address, self.minter, self.minterOwner);
    }
}
