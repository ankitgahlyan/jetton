//  SPDX-License-Identifier: MIT
//  Copyright © 2025 TON Studio

import "./messages";
import "./constants";
import "./shard-utils";
import "./send";
import "../utils";

// TODO: implement traits ownableTransferable(to nominee) or internal update, delayedUpgradable
// TODO: p2p upgrades of walletcode + mbrpAmount etc using minter's signed payload
// call minter to update constants(mbrp) but only upwards is possible
//TODO: api to change invitor when/where fees goes for public works
//TODO: change gas co n sts
// ERROR_CODES ===============================================================================================================
const INCORRECT_SENDER: Int = 700;
const ACCOUNT_TERMINATED: Int = 701;
const ACCOUNT_INACTIVE: Int = 702;
const INSUFFICIENT_TON: Int = 703;
const RESERVED_INTERNAL: Int = 704;
//const MAX_CONNECTIONS: Int = 705;
const NO_PENDING_REQUEST: Int = 706;
const CANT_UNFOLLOW_REPORTED: Int = 707;
const SELF_DISPUTE_NOT_ALLOWED: Int = 708;
const INSUFFICIENT_BALANCE: Int = 709;
const ALREADY_REPORTED: Int = 710;
const ACCOUNT_NOT_REPORTED: Int = 711;
const NOT_AUTHORIZED: Int = 712;

// CONTRACT_CONSTS ===========================================================================================================
const MAX_CONNECTIONS: Int = 250; //coz of msg sending constraints

contract JettonWalletSharded {
    //STOP incoming tokens txn after transferredto nominee
    //id token: signed payload by master
    // CONTRACT_PERSISTENT_STORE =============================================================================================
    owner: Address;
    minter: Address; // treat as treasury + sudo(unbacked minting & force transfer like in governance), use dao address
    minterOwner: Address;
    balance: Int as coins = ton("1");
    nominee: Address?;
    invitor: Address?;//guarantor/offchain-contact responsible for kyc + education + proposal, propagator,TODO: nominee is appointed for all invited after it's demise; inactive account if null(no ops allowed perhaps)
    invited: map<Address, Int as uint12>;//TODO: need counter/check?or default exitCode5isEnough
    friends: map<Address, Int as uint12>;//if following followsBack or follower is followedBack then add here and remove there for saving time/compute & space/storage
    pendingRequests: map<Address, Int as uint12>;
    followers: map<Address, Int as uint12>;
    followings: map<Address, Int as uint12>;//4096 TODO: use max 255 coz of !storage/msg constraints
    debts: map<Address, Int as uint20>;//1,048,576, mbrp*maxConnections(friends+fans+faned)
    reports: map<Address, Bool>; //TODO: consider reporter side data store then support and dispute there for less txns,tradeoff -> only one report at aTime
    reportReason: Bool = false; // true for genuineClosingOnDeath, false for fraud/duplicateIdsAccounts
    reporterCount: Int as uint10 = 0; //TODO: delegate2dao/admin handles out of range complaints
    disputerCount: Int as uint10 = 0;//1024
    reportResolutionTime: Int as uint32 = 0;//4,294,967,296
    connectionsCount: Int as uint8 = 0;//256
    terminated: Bool = false;
    //bloacklist: map<Address, Int as uint8>;//blocklist+blacklist
    //adminOps
    // Dynamically adjustable configuration parameters
    mbrpAmount: Int as coins = ton("1000");
    closureWait: Int as uint32 = 86400;
    freeze: Bool = false;
    //stores coz of chain/design constraints
    lastFollower: Address?;//for reversing bounced msg
    lastFollowing: Address?;
    lastFriend: Address?;

    //======================================================INIT==============================================================
    init(owner: Address, minter: Address , minterOwner: Address) { //TODO: take coordinates
        self.owner = owner;
        self.minter = minter;
        self.minterOwner = minterOwner;
        //notify TODO: or on invite
    }

    //====================================================RECEIVERS===========================================================
    receive(msg: JettonTransfer) {
        let sender = sender(); //TODO: Check whole callChain if var is used? twice?
        let receiver = msg.destination;
        let amount = msg.amount;

        throwUnless(INCORRECT_SENDER, sender == self.owner);
        throwUnless(ACCOUNT_TERMINATED, !self.terminated);//rootCanRestorejustinCase
        throwUnless(ACCOUNT_INACTIVE, self.invitor != null || self.owner == self.minter);//TODO:
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
            (2 * getComputeFee(gasForTransfer, false) + minTonsForStorage)
        );

        if (amount < ton("1")) {
            if (amount == ton("0.1")) { //send friendRequest
                self.friendRequest(receiver, self.mbrpAmount);
            } else if (amount == ton("0.2")) {
                self.confirmFRequest(receiver, msg);
            } else if (amount == ton("0.3")) { // 0.2 token - report duplicateId
                self.report(sender, receiver, false, msg); //redundant?TODO:
            } else if (amount == ton("0.4")) { // 0.5 token - report onDeath
                self.report(sender, receiver, true, msg);
            } else if (amount == ton("0.5")) { // 0.3 token - dispute
                self.dispute(sender, receiver);
            } else if (amount == ton("0.6")) { // 0.4 token - process report
                self.reportResolution();
            } else if (amount == ton("0.7")) { // 0.4 token - process report
                self.nominee = receiver;
                //self.changeNominee(receiver);
                return; //maybe notify msg.destination
            } else if (amount == ton("0.9")) { // 0.1 token - invite/follow/unfollow
                self.folllow(receiver, self.mbrpAmount); //TODO: location params from custom payload forwardPayload
            } else if (amount == ton("0.11")) { //clean requests to free contract storage
                self.clearAllRequests();
            } else if (amount == ton("0.01") || amount == ton("0.02") || amount == ton("0.03")) { // reserved for invite
                throwUnless(RESERVED_INTERNAL, false); //invite(mbrp),burn, reward(2xmbrp)
            } else if (sender == self.minter) { // Admin operations (owner only)
                self.adminAction(msg);
            }
        } else {
            self.transfer(amount);
        } // Standard transfer

        //let destinationShard = receiver.getShard();

        DeployParameters {
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: JettonTransferInternal {
                queryId: msg.queryId,
                amount,
                sender,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),
            init: self.getInit(msg.destination),
        }.toShard(receiver.getShard()).send();
    }

    receive(msg: JettonTransferInternal) {
        throwUnless(ACCOUNT_TERMINATED, !self.terminated); //deadPersonsAccounts or duplicateClosedaAccs
        let sender = msg.sender;
        let senderC = sender();
        let amount = msg.amount;

        // This message should come only from other JettonWallet or minter/sudo
        let wallet: StateInit = self.getInit(sender);
        if (!(wallet.hasSameBasechainAddressWithoutShard(senderC))) {
            //TODO: master can't mint so remove and return
            throwUnless(INCORRECT_SENDER, self.minter == sender());
        }

        if (amount != ton("0.1")) {
            throwUnless(ACCOUNT_INACTIVE, self.invitor != null || sender == self.minterOwner);
        }

        if (amount < ton("1")) { //special/semantic txns.
            if (amount == ton("0.1")) { // friend request
                self.friendRequestInternal(sender, senderC, msg);
            } else if (amount == ton("0.2")) { // confirm request
                self.confirmFRequestInternal(sender);
            } else if (amount == ton("0.3")) { //report duplicateIds
                self.reportInternal(sender, true, msg);
            } else if (amount == ton("0.4")) { //report accClosureOnDeath
                self.reportInternal(sender, false, msg);
            } else if (amount == ton("0.5")) { // 0.3 token - dispute
                self.disputeInternal(sender);
            } else if (amount == ton("0.6")) { // 0.4 token - process report
                self.reportResolutionInternal(msg);
            } else if (amount == ton("0.9")) { // 0.1 token - invite/follow/unfollow
                self.folllowInternal(sender, senderC, msg); //TODO: location params from custom payload/forwardPayload
            } else if (sender == self.minter) { // Admin operations (owner only)
                self.adminActionInternal(msg);
            }
        } else {
            self.transferInternal(amount, msg.sender);
        } // Standard transfer
        let ctx: Context = context();
        let msgValue: Int = ctx.value;
        let tonBalanceBeforeMsg = myBalance() - msgValue;

        if (msg.forwardTonAmount > 0) {
            let fwdFee: Int = ctx.readForwardFee();
            msgValue -= msg.forwardTonAmount + fwdFee;
            MessageParameters {
                to: self.owner,
                value: msg.forwardTonAmount,
                mode: SendPayGasSeparately,
                bounce: false,
                body: JettonNotification { // 0x7362d09c -- Remind the new Owner
                    queryId: msg.queryId,
                    amount,
                    sender,
                    forwardPayload: msg.forwardPayload,
                }.toCell(),
            }.send();
        }
        nativeReserve(max(tonBalanceBeforeMsg, minTonsForStorage), ReserveAtMost);
        // 0xd53276db -- Cashback to the original Sender
        if (msg.responseDestination != null && msgValue > 0) {
            MessageParameters {
                to: msg.responseDestination!!,
                value: msgValue,
                mode: SendRemainingBalance | SendIgnoreErrors,
                bounce: false,
                body: JettonExcesses { queryId: msg.queryId }.toCell(),
            }.send();
        }
    }

    //====================================================INTERNAL_FUNCTIONS==================================================
    inline fun friendRequest(target: Address, amount: Int) {
        // Ensure we have room for new connections before creating a pending request
        throwUnless(MAX_CONNECTIONS, self.connectionsCount < MAX_CONNECTIONS);
        if (self.followers.exists(target)) {
            self.folllow(target, amount);
        }
    }

    inline fun friendRequestInternal(sender: Address, senderC: Address, msg: JettonTransferInternal) {
        if (self.invitor == null) {
            self.invite(sender, senderC, msg);//TODO: 
            return;
        }
        if (self.followings.exists(sender)) {
            self.folllowInternal(sender, senderC, msg);
            return;
        }
        self.pendingRequests.set(sender, self.mbrpAmount);
    }

    inline fun confirmFRequest(target: Address, msg: JettonTransfer) {
        // Confirm a pending friend request and create mutual friendship
        throwUnless(NO_PENDING_REQUEST, self.pendingRequests.exists(target));
        // Do not exceed max connections
        throwUnless(MAX_CONNECTIONS, self.connectionsCount < MAX_CONNECTIONS);

        if (self.followers.exists(target)) { //follower sends request
            let _ = self.followers.del(target);
        } else {
            self.transferInternal(self.mbrpAmount, target);
        }

        self.friends.set(target, self.mbrpAmount);
        self.lastFriend = target;
        let _ = self.pendingRequests.del(target);
        self.connectionsCount += 1;
    }

    inline fun confirmFRequestInternal(sender: Address) {
        if (!self.followers.exists(sender)) {
            //mint
            self.transferInternal(self.mbrpAmount, sender);
        }
        self.friends.set(sender, self.mbrpAmount);
        self.connectionsCount += 1;
    }

    inline fun clearAllRequests() {
        if (!self.pendingRequests.isEmpty()) {
            self.pendingRequests = null; //emptyMap();
        }
        emit("clearedPendingRequests".asComment()); //TODO: handle events
    }

    // Optimized follow logic with reduced state reads
    inline fun folllow(target: Address, amount: Int) {
        //let amount = self.mbrpAmount;//TODO:update using call to minter upwards only possible

        //require(sender != target, "can't follow self");//handle bad behaviour by reports(optimistic approach)
        if (self.friends.exists(target) || self.followings.exists(target)) {
            self.processUnfollow(target);
            return;
        }

        if (self.followers.exists(target)) {
            // Create friends only if capacity allows
            throwUnless(MAX_CONNECTIONS, self.connectionsCount < MAX_CONNECTIONS);

            //let _ = self.followings.del(target);
            let _ = self.followers.del(target);
            // store friendship marker (use mbrpAmount as stored value)
            self.friends.set(target, self.mbrpAmount);
            // track last friend created
            self.lastFriend = target;
            self.connectionsCount += 1;
        } else {
            self.followings.set(target, amount);
            // remember last following created (owner follows target)
            self.lastFollowing = target;
        }
    }

    inline fun folllowInternal(sender: Address, senderC: Address, msg: JettonTransferInternal) {
        if (self.invitor == null && self.followers.isEmpty()) {
            self.invite(sender, senderC, msg);
            return;
        }
        if (self.followers.exists(sender)) {
            self.unfollowInternal(msg);
            return;
        }

        self.balance += self.mbrpAmount;

        // If we already follow that address, upgrade to friends and remove single-sided entries
        if (self.followings.exists(sender)) {
            // Create friends only if capacity allows
            throwUnless(MAX_CONNECTIONS, self.connectionsCount < MAX_CONNECTIONS);

            let _ = self.followings.del(sender);
            self.friends.set(sender, self.mbrpAmount);
            self.connectionsCount += 1;
        } else {
            self.followers.set(sender, self.mbrpAmount);
            self.connectionsCount += 1;
        }

        //TODO: tells follower's followers about this follow or invite and add to network
        //emitEvent(1, msg.sender, self.owner, msg.amount);
    }

    inline fun invite(sender: Address, senderC: Address, msg: JettonTransferInternal) {
        self.friends.set(msg.sender, self.mbrpAmount);
        self.invitor = sender;
        self.nominee = sender;
        // track last follower created by invite
        self.lastFriend = sender;
        //TODO: auto follows invitor & on unfollow invitor puts in bloacklist
        //TODO: mint in sender
        MessageParameters {
            to: senderC,
            value: 0,
            mode: SendRemainingValue,
            body: JettonTransferInternal {
                queryId: msg.queryId, //FIXME: queryid passing with care
                amount: ton("0.01"),
                sender: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),
        }.send();
    }

    inline fun processUnfollow(target: Address) {
        // If this was a mutual friendship, breaking the follow should turn it into a one-sided follower
        if (self.friends.exists(target)) {
            // owner stops following target; target still follows owner -> move to followers
            let _ = self.friends.del(target);
            self.followers.set(target, self.mbrpAmount);
        } else {
            let _ = self.followings.del(target);
        }

        if (self.connectionsCount > 0) {
            self.connectionsCount -= 1;
        }
        // Otherwise just remove the following entry
        let _ = self.followings.del(target);
        if (self.invited.exists(target)) {
            self.internalBurn(target, self.mbrpAmount);
            //self.balance -= amount;
        }
    }

    inline fun unfollowInternal(msg: JettonTransferInternal) {
        throwUnless(CANT_UNFOLLOW_REPORTED, self.reporterCount == 0);
        let sender = msg.sender;

        // If they were friends, breaking follower side makes owner still follow them -> move to followings
        if (self.friends.exists(sender)) {
            let _ = self.friends.del(sender);
            self.followings.set(sender, self.mbrpAmount);
        } else {
            let _ = self.followers.del(sender);
        }

        if (self.connectionsCount > 0) {
            self.connectionsCount -= 1;
        }
        let _ = self.followers.del(sender);

        if (sender == self.invitor) {
            self.invitor = null;
            //already burned from other
        } else { //burn from self
            self.internalBurn(sender, self.mbrpAmount);
            //self.balance -= amount;
        }
    }

    inline fun report(sender: Address, target: Address, reason: Bool, msg: JettonTransfer) {
        //require target is from same contract
        //require(target != self.owner || myAddress(), "Cannot report self");//programmedInHumans
        throwUnless(SELF_DISPUTE_NOT_ALLOWED, target != self.minter);
        // if (target == self.minter) {//govtWay of discouraging smartAsses/badBehaviour(stick over carrot)
        //     self.balance -= self.balance;
        //     require(false, "uROfficiallyFuckedBruhh!");
        // }
        self.balance -= self.mbrpAmount;
        throwUnless(INSUFFICIENT_BALANCE, self.balance >= 0);
    }

    inline fun reportInternal(sender: Address, reason: Bool, msg: JettonTransferInternal) {
        //TODO: invitor auto disputes or noneed (consider disputed implicitly)
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
        let receiverAddr = contractShardBasechainAddress(walletInit);
        //burn/stake from target's invitor once in case of duplicateId only
        if (reason && self.reports == null) {
            DeployParameters {
                value: 0,
                mode: SendRemainingValue,
                bounce: true, //TODO: handle bouncing everywhere
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

    inline fun dispute(sender: Address, target: Address) {
        //stake
        throwUnless(SELF_DISPUTE_NOT_ALLOWED, target != self.minter);
        throwUnless(SELF_DISPUTE_NOT_ALLOWED, sender != target);
        self.balance -= self.mbrpAmount;
        throwUnless(INSUFFICIENT_BALANCE, self.balance >= 0);
    }

    inline fun disputeInternal(sender: Address) {
        throwUnless(ACCOUNT_NOT_REPORTED, self.reporterCount > 0);
        self.reports.set(sender, false);
        self.disputerCount += 1;
        self.reportResolutionTime = now() + self.closureWait;
    }

    inline fun reportResolution() {}

    //TODO: batch msg about total dec in conn. on close
    inline fun reportResolutionInternal(msg: JettonTransferInternal) {
        throwUnless(NO_PENDING_REQUEST, self.reportResolutionTime > 0); //notOptional it's semantic otherwise need null
        throwUnless(INSUFFICIENT_TON, now() >= self.reportResolutionTime);

        let reporters = self.reporterCount;
        let disputers = self.disputerCount;

        // decide winner
        // reporters should be more than disputers no ties allowed
        let reportWinCloseAcc: Bool = reporters > disputers; //>= IF invitor NOT disputes bydefault 

        // reward winners 2x mbrp(stake+reward), lossers lose stake
        let losersCount: Int = 0;
        if (reportWinCloseAcc) {
            losersCount = disputers;
        } else {
            losersCount = reporters;
        }
        let rewarded: Int = 0;

        // Distribute rewards: first `losersCount` winners get 2x, remaining winners get 1x.
        // Remove entries as we process them so the following foreach (below) becomes a no-op.
        foreach (addr, flag in self.reports) { //TODO: can send only around 250 msg(maybe keep count & send last msg to self to process remaining txns),forNow maxConn are 200
            // determine if this entry is a winner
            if ((flag && reportWinCloseAcc) || (!flag && !reportWinCloseAcc)) {
                let reward: Int = 0;
                if (rewarded < losersCount) {
                    reward = ton("0.03"); // 2x mbrp
                    rewarded += 1;
                } else {
                    reward = ton("0.01"); // release stake (1x mbrp)
                }

                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0,
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

        if (reportWinCloseAcc) {
            // Unfollow all and burn from followers/followings/friends.
            // If address is in friends -> treat as both in followings and followers

            // First iterate followings
            foreach (addr, _ in self.followings) {
                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0,
                        amount: ton("0.02"),
                        sender: self.owner,
                        responseDestination: null,
                        forwardTonAmount: 0,
                        forwardPayload: msg.forwardPayload,
                    }.toCell(),
                }.send();

                if (self.connectionsCount > 0) {
                    self.connectionsCount -= 1;
                }
                let _ = self.followings.del(addr);
            }

            // Now handle remaining followers
            foreach (addr, _ in self.followers) {
                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0,
                        amount: ton("0.02"),
                        sender: self.owner,
                        responseDestination: null,
                        forwardTonAmount: 0,
                        forwardPayload: msg.forwardPayload,
                    }.toCell(),
                }.send();

                let _ = self.followers.del(addr);
            }

            // Now handle remaining followers
            foreach (addr, _ in self.friends) {
                MessageParameters {
                    to: contractAddress(self.getInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0,
                        amount: ton("0.03"), //2x burn
                        sender: self.owner,
                        responseDestination: null,
                        forwardTonAmount: 0,
                        forwardPayload: msg.forwardPayload,
                    }.toCell(),
                }.send();
                let _ = self.friends.del(addr);
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

    inline fun transfer(amount: Int) {
        //TODO: if (self.balance < 0) {adjust debts}//consider using debts only instead of -veBalance
        self.balance -= amount;
        throwUnless(INSUFFICIENT_BALANCE, self.balance >= 0);
    }

    inline fun transferInternal(amount: Int, sender: Address) {//TODO: adjust this logic in receiver maybe
        if (amount == ton("0.01")) { //invite
            amount = self.mbrpAmount;
            self.invited.set(sender, self.mbrpAmount); //TODO: Bool instead of mbrp
            self.friends.set(sender, self.mbrpAmount);
            let _ = self.followings.del(sender);
        } else if (amount == ton("0.02")) { //from internalreport invitor burn
            self.internalBurn(sender, self.mbrpAmount); //TODO: need modular funs  
            return;
        } else if (amount == ton("0.03")) {
            amount = 2 * self.mbrpAmount;
        }
        amount = self._deductDebt(amount);
        self.balance += amount;
    }

    // fun changeNominee(nominee: Address) {//small logic, so adjusted in receiver
    //     self.nominee = nominee;
    // }
    fun adminAction(msg: JettonTransfer) {}

    fun adminActionInternal(msg: JettonTransferInternal) {}

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
        // Revert storage changes caused by semantic operations or transfers that failed
        if (msg.amount < ton("1")) {
            // friend request (pending request) failed
            if (msg.amount == ton("0.2")) {
                
                if (self.lastFriend != null) {
                    
                }
            } else if (msg.amount == ton("0.9")) { // follow / invite operations
                // If a follower record was just created, revert it and adjust balance
                if (self.lastFollower != null) {
                    let lastFollower = self.lastFollower!!;
                    if (self.followers.exists(lastFollower)) {
                        let _ = self.followers.del(lastFollower);
                    }
                    // revert minted reward on follower creation
                    if (self.balance >= self.mbrpAmount) {
                        self.balance -= self.mbrpAmount;
                    } else {
                        self.balance = 0;
                    }
                    self.lastFollower = null;
                    if (self.connectionsCount > 0) { self.connectionsCount -= 1; }
                }

                // If a following was just created by owner, revert it
                if (self.lastFollowing != null) {
                    let lf = self.lastFollowing!!;
                    if (self.followings.exists(lf)) {
                        let _ = self.followings.del(lf);
                    }
                    self.lastFollowing = null;
                }

                // If a friendship was just established, revert it
                if (self.lastFriend != null) {
                    let lfnd = self.lastFriend!!;
                    if (self.friends.exists(lfnd)) {
                        let _ = self.friends.del(lfnd);
                        if (self.connectionsCount > 0) { self.connectionsCount -= 1; }
                    }
                    self.lastFriend = null;
                }
            } else if (msg.amount == ton("0.3") || msg.amount == ton("0.4") || msg.amount == ton("0.5")) {
                // refund stake
                self.balance += self.mbrpAmount;//needAdjustDebt?               
            } else {
                // Other small semantic amounts: nothing to revert by default
            }
        } else {
            // Standard transfer failed — refund the balance
            self.balance += msg.amount;
        }
    }

    bounced(msg: bounced<JettonBurnNotification>) {
        self.balance += msg.amount;
    }

    // helpers
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

    inline fun internalBurn(unfollower: Address, amount: Int) {
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
        if (self.debts.exists(unfollower)) {
            prevDebt = self.debts.get(unfollower)!!;
        }
        self.debts.set(self.minter, prevDebt + shortfall);
    }

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