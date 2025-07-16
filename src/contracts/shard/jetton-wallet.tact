//  SPDX-License-Identifier: MIT
//  Copyright © 2025 TON Studio

import "./messages";
import "./constants";
import "./shard-utils";
import "./send";
import "../utils";

//TODO: USE initof deploy to pass id(need for ? ) mapping
// TODO: implement traits ownableTransferable(to nominee) or internal update, delayedUpgradable
// TODO: p2p upgrades of walletcode + mbrpAmount etc using minter's signed payload
// call minter to update constants(mbrp) but only upwards is possible
//TODO: MINT to owner 1 token on init and to minter on master init
//TODO: api to change invitor when/where fees goes for public works
//TODO: change gas co n sts
contract JettonWalletSharded {//FossFiatWallet
    //STOP incoming tokens txn after transferredto nominee
    //id token: signed payload by master
    owner: Address; // wallet w5 contract(customizable)
    minter: Address; // treat as treasury + sudo(unbacked minting & force transfer like in governance)
    balance: Int as coins = ton("1"); //jettons r != tons
    nominee: Address = emptyAddress(); // beneficiary; emptyAddress() as sentinel for "not set"
    invitor: Address = emptyAddress(); //guarantor/offchain-contact responsible for kyc + education + proposal, propagator,TODO: nominee is appointed for all invited after it's demise; inactive account if null(no ops allowed perhaps)
    invited: map<Address, Int as uint8>; //Array?,TODO: WHAThappens when uint8 is full
    friends: map<Address, Int as uint16>; //if following followsBack or follower is followedBack then add here and remove there for saving time & space
    pendingRequests: map<Address, Int as uint16>;
    followers: map<Address, Int as uint16>; //TODO: make uint and change used INITS, atleast invitor follows so can't be null, OR CANBE INACTIVE ACCOUNTS
    followings: map<Address, Int as uint16>; //TODO: use max 1k coz of storage constraints
    debts: map<Address, Int as uint32>; //use foreach
    reports: map<Address, Bool>; //TODO: consider reporter side data store then support and dispute there for less txns
    reportReason: Bool = false; // true for genuineClosingOnDeath, false for fraud/duplicateIdsAccounts; default false meaning "unset/false"
    reporterCount: Int as uint16 = 0;
    disputerCount: Int as uint16 = 0;
    reportResolutionTime: Int as uint32 = 0;
    connectionsCount: Int as uint8 = 0;
    terminated: Bool = false;
    //bloacklist: map<Address, Int as uint8>;//blocklist+blacklist
    //adminOps
    maxConnections: Int as uint8 = 200; //FIXME: deranged?
    mbrpAmount: Int as coins = ton("1000");
    closureWait: Int as uint16 = 86400;
    freeze: Bool = false;

    init(owner: Address, minter: Address) { //TODO: take coordinates
        //self.balance = ton("1");//TODO: OK?
        self.owner = owner;
        self.minter = minter;
        //self.nominee = sender(); //TODO: consider storing contrAddresses as contacts
    }

    receive(msg: JettonTransfer) {
        let sender = sender();
        let receiver = msg.destination;
        let amount = msg.amount;

        require(sender == self.owner, "Incorrect sender");//self.root
        require(!self.terminated, "accountTerminated"); //rootCanRestoreTODO:
        require(self.invitor != emptyAddress(), "yourAccountIsInactive"); //allOps r paused, accfreeze
        forceBasechain(receiver);

        checkEitherForwardPayload(msg.forwardPayload);

        let ctx = context();
        let fwdCount = 1 + sign(msg.forwardTonAmount); // msg.forwardTonAmount is coins, so it's positive
        require(
            ctx.value >
            msg.forwardTonAmount +
            fwdCount * ctx.readForwardFee() +
            getForwardFee(walletStateInitCells, walletStateInitBits, false) +
            (2 * getComputeFee(gasForTransfer, false) + minTonsForStorage),
            "Insufficient amount of TON attached",
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
                self.reportResolution(sender, receiver, msg);
            } else if (amount == ton("0.7")) { // 0.4 token - process report
                self.nominee = receiver;
                //self.changeNominee(receiver);
                return; //maybe notify msg.destination
            } else if (amount == ton("0.9")) { // 0.1 token - invite/follow/unfollow
                self.folllow(receiver, self.mbrpAmount, msg); //TODO: location params from custom payload forwardPayload
            } else if (amount == ton("0.01") || amount == ton("0.02") || amount == ton("0.03")) { // reserved for invite
                require(false, "reservedAmountForInternalOps"); //invite(mbrp),burn, reward(2xmbrp)
            } else if (sender == self.minter) { // Admin operations (owner only)
                self.adminAction(msg);
            }
        } else {
            self.processTransfer(msg);
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
            init: self.getJettonWalletInit(receiver),
        }.toShard(receiver.getShard()).send();
    }

    receive(msg: JettonTransferInternal) {
        require(!self.terminated, "accountTerminated");
        let sender = msg.sender;
        let amount = msg.amount;

        // This message should come only from other JettonWallet or minter/sudo
        let wallet: StateInit = self.getJettonWalletInit(sender);
        if (!(wallet.hasSameBasechainAddressWithoutShard(sender()))) {
            //TODO: master can't mint so remove and return
            require(self.minter == sender(), "Incorrect sender");
        }
        if (amount != ton("0.1")) {
            require(self.invitor != emptyAddress(), "receiverAccountIsInactive");
        }

        if (amount < ton("1")) { //special/semantic txns.
            if (amount == ton("0.1")) { // friend request
                self.friendRequestInternal(sender);
            } else if (amount == ton("0.2")) { // confirm request
                self.confirmFRequestInternal(sender);
            } else if (amount == ton("0.3")) { //report duplicateIds
                self.reportInternal(sender, true, msg);
            } else if (amount == ton("0.4")) { //report accClosureOnDeath
                self.reportInternal(sender, false, msg);
            } else if (amount == ton("0.5")) { // 0.3 token - dispute
                self.disputeInternal(sender);
            } else if (amount == ton("0.6")) { // 0.4 token - process report
                self.reportResolutionInternal(sender);
            } else if (amount == ton("0.9")) { // 0.1 token - invite/follow/unfollow
                self.folllowInternal(sender(), msg); //TODO: location params from custom payload/forwardPayload
            } else if (sender == self.minter) { // Admin operations (owner only)
                self.adminActionInternal(amount, msg.destination);
            }
        } else {
            self.transferInternal(amount, msg);
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

    inline fun friendRequest(target: Address, amount: Int) {
        // Ensure we have room for new connections before creating a pending request
        require(self.connectionsCount < self.maxConnections, "maxConnectionsReached");
    }

    inline fun friendRequestInternal(sender: Address, amount: Int) {
        self.pendingRequests.set(sender, amount);
    }

    inline fun confirmFRequest(target: Address, msg: JettonTransfer) {
        // Confirm a pending friend request and create mutual friendship
        require(self.pendingRequests.exists(target), "noPendingRequest");
        // Do not exceed max connections
        require(self.connectionsCount < self.maxConnections, "maxConnectionsReached");

        // Remove any one-sided entries and create friends entry
        if (self.followings.exists(target)) {
            let _ = self.followings.del(target);
        }
        if (self.followers.exists(target)) {
            let _ = self.followers.del(target);
        }

        self.friends.set(target, self.mbrpAmount);
        let _ = self.pendingRequests.del(target);
        self.transferInternal(self.mbrpAmount, target);
        self.connectionsCount += 1;
    }

    inline fun confirmFRequestInternal(sender: Address) {
        if (!self.followers.exists(sender)) {
            //mint
            self.transferInternal(self.mbrpAmount, sender);
        }
    }

    // Optimized follow logic with reduced state reads
    inline fun folllow(target: Address, amount: Int, msg: JettonTransfer) {
        //let amount = self.mbrpAmount;//TODO:update using call to minter upwards only possible

        //require(sender != target, "can't follow self");//handle bad behaviour by reports(optimistic approach)
        if (self.friends.exists(target) || self.followings.exists(target)) {
            self.processUnfollow(target);
            return;
        }

        if (self.followers.exists(target)) {
            // Create friends only if capacity allows
            require(self.connectionsCount < self.maxConnections, "maxConnectionsReached");

            //let _ = self.followings.del(target);
            let _ = self.followers.del(target);
            // store friendship marker (use mbrpAmount as stored value)
            self.friends.set(target, self.mbrpAmount);
            self.connectionsCount += 1;
        } else {
            self.followings.set(target, amount);
        }
    }

    inline fun folllowInternal(senderContract: Address, msg: JettonTransferInternal) {
        if (self.invitor == emptyAddress() && self.followers.isEmpty()) {
            self.processInvite(senderContract, msg);
            return;
        }
        if (self.followers.exists(msg.sender)) {
            self.processUnfollowInternal(msg);
            return;
        }

        self.balance += self.mbrpAmount;

        // If we already follow that address, upgrade to friends and remove single-sided entries
        if (self.followings.exists(msg.sender)) {
            // Create friends only if capacity allows
            require(self.connectionsCount < self.maxConnections, "maxConnectionsReached");

            let _ = self.followings.del(msg.sender);
            self.friends.set(msg.sender, self.mbrpAmount);
        } else {
            self.followers.set(msg.sender, self.mbrpAmount);
            self.connectionsCount += 1;
        }

        //TODO: tells follower's followers about this follow or invite and add to network
        //emitEvent(1, msg.sender, self.owner, msg.amount);
    }

    inline fun processInvite(senderC: Address, msg: JettonTransferInternal) {
        self.followers.set(msg.sender, ton("1"));
        self.balance += ton("1");
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

    inline fun processUnfollowInternal(msg: JettonTransferInternal) {
        require(self.reporterCount == 0, "canTUnfollowReported");
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
            self.invitor = emptyAddress();
            //already burned from other
        } else { //burn from self
            self.internalBurn(sender, self.mbrpAmount);
            //self.balance -= amount;
        }
    }

    inline fun report(sender: Address, target: Address, reason: Bool, msg: JettonTransfer) {
        //require target is from same contract
        //require(target != self.owner || myAddress(), "Cannot report self");//programmedInHumans
        require(target != self.minter, "noNoNo");
        // if (target == self.minter) {//govtWay of discouraging smartAsses/badBehaviour(stick over carrot)
        //     self.balance -= self.balance;
        //     require(false, "uROfficiallyFuckedBruhh!");
        // }
        self.balance -= self.mbrpAmount;
        require(self.balance >= 0, "insufficientBalance");
    }

    inline fun reportInternal(sender: Address, reason: Bool, msg: JettonTransferInternal) {
        //TODO: invitor auto disputes
        if (reason) {
            self.reportReason = reason;
        } //false byDefault//TODO: reason complete?
        require(self.invitor != emptyAddress(), "accountIsInactiveOrNonExistent");
        require(!self.reports.exists(sender), "alreadyReported");
        self.reports.set(sender, true);
        self.reporterCount += 1;
        self.reportResolutionTime = now() + self.closureWait; //TODO: INC time onlyIf this overtakes others(disputers)

        let receiver = self.invitor; // emptyAddress() sentinel handled by require above
        let walletInit = getJettonWalletInit(receiver);
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
                init: walletInit, //self.getJettonWalletInit(receiver),
            }.toShard(receiver.getShard()).send();
        }
    }

    inline fun dispute(sender: Address, target: Address) {
        //stake
        require(target != self.minter, "noNoNo");
        require(sender != target, "can'tDisputeSelf");
        self.balance -= self.mbrpAmount;
        require(self.balance >= 0, "insufficientBalance");
    }

    inline fun disputeInternal(sender: Address) {
        require(self.reporterCount > 0, "accountNotReported");
        self.reports.set(sender, false);
        self.disputerCount += 1;
        self.reportResolutionTime = now() + self.closureWait;
    }

    inline fun reportResolution() {}

    inline fun reportResolutionInternal() {
        require(self.reportResolutionTime > 0, "noReportPending");
        require(now() >= self.reportResolutionTime, "waitUntilResolutionTime");

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
        foreach (addr, flag in self.reports) { //TODO: can send only around 250 msg(maybe keep count & send last msg to self to process remaining txns)
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
                    to: contractShardBasechainAddress(self.getJettonWalletInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0,
                        amount: reward,
                        sender: self.owner,
                        responseDestination: null,
                        forwardTonAmount: 0,
                        forwardPayload: null,
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
                let inFollowers: Bool = self.followers.exists(addr) || self.friends.exists(addr);

                let burnAmount: Int = 0;
                if (inFollowers) {
                    burnAmount = ton("0.03");
                } else {
                    burnAmount = ton("0.02");
                }

                MessageParameters {
                    to: contractShardBasechainAddress(self.getJettonWalletInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0,
                        amount: burnAmount,
                        sender: self.owner,
                        responseDestination: null,
                        forwardTonAmount: 0,
                        forwardPayload: null,
                    }.toCell(),
                }.send();

                // Remove relations: if friend, remove friend and also remove follower entry
                if (self.friends.exists(addr)) {
                    let _ = self.friends.del(addr);
                    let _ = self.followers.del(addr);
                    if (self.connectionsCount > 0) {
                        self.connectionsCount -= 1;
                    }
                }
                let _ = self.followings.del(addr);
            }

            // Now handle remaining followers that were not in followings (and not in friends)
            foreach (addr, _ in self.followers) {
                if (self.friends.exists(addr)) {
                    continue;
                }

                // only in followers -> single burn
                MessageParameters {
                    to: contractShardBasechainAddress(self.getJettonWalletInit(addr)),
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: true,
                    body: JettonTransferInternal {
                        queryId: 0,
                        amount: ton("0.02"),
                        sender: self.owner,
                        responseDestination: null,
                        forwardTonAmount: 0,
                        forwardPayload: null,
                    }.toCell(),
                }.send();

                //let _ = self.followers.del(addr);
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

    inline fun processTransfer(msg: JettonTransfer) {
        //TODO: if (self.balance < 0) {adjust debts}//consider using debts only instead of -veBalance
        self.balance -= amount;
        require(self.balance >= 0, "Incorrect balance after send");
    }

    inline fun transferInternal(amount: Int, sender: Address ) {
        if (amount == ton("0.01")) { //invite
            amount = self.mbrpAmount;
            self.invited.set(sender, self.mbrpAmount); //TODO: Bool instead of mbrp
        } else if (amount == ton("0.02")) { //from internalreport invitor burn
            self.internalBurn(sender, self.mbrpAmount); //TODO: need modular funs  
            return;
        } else if (amount == ton("0.03")) {
            amount = 2 * self.mbrpAmount;
        }
        amount = self._deductDebt(amount);
        self.balance += amount;
    }

    // fun changeNominee(nominee: Address) {
    //     self.nominee = nominee;
    // }

    receive(msg: ProvideWalletBalance) {
        require(!self.terminated, "accountTerminated");
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
        require(!self.terminated, "accountTerminated");
        // we can skip forceBasechain here because with other checks in place it's not possible
        // to acquire jettons outside of basechain, so amount check is enough
        require(sender() == self.owner, "Incorrect sender");

        self.balance -= msg.amount;
        require(self.balance >= 0, "Incorrect balance after send");

        let ctx = context();
        let fwdFee: Int = ctx.readForwardFee();
        require(ctx.value > (fwdFee + 2 * getComputeFee(gasForBurn, false)), "Insufficient amount of TON attached");

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
        require(!self.terminated, "accountTerminated");
        require(sender() == self.owner, "Incorrect sender");
        nativeReserve(minTonsForStorage, ReserveExact | ReserveBounceIfActionFail);

        // we allow bounce here and don't handle it, if claim fails we just accept the TONs back
        MessageParameters {
            to: msg.receiver,
            value: 0,
            mode: SendRemainingBalance,
        }.send();
    }

    receive("updateMBRP") {
        require(!self.terminated, "accountTerminated");
        //TODO: v2
    }

    bounced(msg: bounced<JettonTransferInternal>) {
        // Revert storage changes caused by semantic operations or transfers that failed
        if (msg.amount < ton("1")) {
            // Handle small semantic amounts (follow, report, dispute, etc.)
            if (msg.amount == ton("0.9")) {
                // friend request failed — remove pending request
                if (self.pendingRequests.exists(msg.sender)) {
                    let _ = self.pendingRequests.del(msg.sender);
                }
            } else if (msg.amount == ton("0.1")) {
                // Follow / unfollow: try to undo any changes in followings/followers/friends maps
                if (self.followings.exists(msg.sender)) {
                    let _ = self.followings.del(msg.sender);
                }
                if (self.followers.exists(msg.sender)) {
                    let _ = self.followers.del(msg.sender);
                }
                if (self.friends.exists(msg.sender)) {
                    let _ = self.friends.del(msg.sender);
                    if (self.connectionsCount > 0) {
                        self.connectionsCount -= 1;
                    }
                }
            } else if (msg.amount == ton("0.2") || msg.amount == ton("0.5") || msg.amount == ton("0.3")) {
                // Reports / process report: revert report entry and adjust counters when possible
                if (self.reports.exists(msg.sender)) {
                    let flag: Bool = self.reports.get(msg.sender)!!;
                    if (flag) {
                        if (self.reporterCount > 0) {
                            self.reporterCount -= 1;
                        }
                    } else {
                        if (self.disputerCount > 0) {
                            self.disputerCount -= 1;
                        }
                    }
                    let _ = self.reports.del(msg.sender);
                }
                self.balance += msg.amount;
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
                break;
            }

            let debt: Int = debtVal;
            if (debt <= 0) {
                let _ = self.debts.del(follower);
                continue;
            }

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
            prevDebt = self.debts.get(unfollower);
        }
        self.debts.set(self.minter, prevDebt + shortfall);
    }



    get fun get_wallet_data(): JettonWalletData {
        require(!self.terminated, "accountTerminated");
        return JettonWalletData {
            balance: self.balance,
            owner: self.owner,
            minter: self.minter,
            code: myCode(),
        };
    }

    get fun get_friends_and_followings(): FriendsAndFollowings {
        require(!self.terminated, "accountTerminated");
        require(self.friends.exists(sender()) || self.followers.exists(sender()), "notAuthorized");
        return FriendsAndFollowings {
            friends: self.friends,
            followings: self.followings,
        }
    }

    fun getJettonWalletInit(address: Address): StateInit {
        return initOf JettonWalletSharded(address, self.minter);
            //myCode(),
            // myAddress(),
            // emptyMap(),
            // myAddress(),
            // 0,
            // map<Address, Int as uint16> {myAddress(): self.mbrpAmount},
            // emptyMap(),
            // emptyMap(),
            // myAddress() sentinel used by default params
        //);
    }
}
