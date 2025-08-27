//  SPDX-License-Identifier: MIT
//  Copyright © 2025 TON Studio

// Optimized action messages with op codes
message(1) InviteInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(2) Follow {
    target: Address;
    amount: Int as uint16;
}

message(3) FollowInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(4) Unfollow {
    target: Address;
    amount: Int as uint16;
}

message(5) UnfollowInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(6) FriendRequestInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(7) ConfirmRequestInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
message(8) ReportInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    reason: Bool;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
message(9) DisputeInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
message(10) ResolutionInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(11) Report {
    target: Address;
    reason: Bool; //true for closure, false for fraud/duplicateAccount
}

message(12) Dispute {
    target: Address;
}

message(13) ProcessComplaint {
    target: Address;
}

message(14) AdminAction {
    action: Int as uint8;
    value: Int as coins;
}

// struct Array {
//     // An array of Int values as a map of Int to Int,
//     // with serialization of its keys to uint16 to save space
//     m: map<Int as uint16, Address>;

//     // Length of the array, defaults to 0
//     length: Int = 0;
// }

// // Compile-time constant upper bound for our map representing an array.
// const MaxArraySize: Int = 5_000; // 5,000 entries max, to stay reasonably far from limits

// // Extension mutation function for adding new entries to the end of the array
// extends mutates fun append(self: Array, item: Address) {
//     require(self.length + 1 <= MaxArraySize, "No space in the array left for new items!");

//     self.m.set(self.length, item); // set the entry (key-value pair)
//     self.length += 1; // increase the length field
// }

// // Extension mutation function for inserting new entries at the given index
// extends mutates fun insert(self: Array, item: Address, idx: Int) {
//     require(self.length + 1 <= MaxArraySize, "No space in the array left for new items!");
//     require(idx >= 0, "Index of the item cannot be negative!");
//     require(idx < self.length, "Index is out of array bounds!");

//     // Move all items from idx to the right
//     let i: Int = self.length; // not a typo, as we need to start from the non-existing place
//     while (i > idx) {
//         // Note that we use the !! operator, as we know for sure the value would be there
//         self.m.set(i, self.m.get(i - 1)!!);
//         i -= 1;
//     }

//     // Insert the new item
//     self.m.set(idx, item); // set the entry (key-value pair)
//     self.length += 1; // increase the length field
// }

// // Extension function for getting the value at the given index
// extends fun getIdx(self: Array, idx: Int): Address {
//     require(self.length > 0, "No items in the array!");
//     require(idx >= 0, "Index of the item cannot be negative!");
//     require(idx < self.length, "Index is out of array bounds!");

//     // Note that we use the !! operator, as we know for sure the value would be there
//     return self.m.get(idx)!!;
// }

// // Extension function for returning the last value
// extends fun getLast(self: Array): Address {
//     require(self.length > 0, "No items in the array!");

//     // Note that we use the !! operator, as we know for sure the value would be there
//     return self.m.get(self.length - 1)!!;
// }

// // Extension mutation function for deleting an entry at the given index and returning its value
// extends mutates fun deleteIdx(self: Array, idx: Int): Address {
//     require(self.length > 0, "No items in the array to delete!");
//     require(idx >= 0, "Index of the item cannot be negative!");
//     require(idx < self.length, "Index is out of array bounds!");

//     // Remember the value that is going to be deleted
//     let memorized = self.m.get(idx)!!;

//     // Move all items from idx onwards to the left
//     let i: Int = idx;
//     while (i + 1 < self.length) {
//         // Note that we use the !! operator, as we know for sure the value would be there
//         self.m.set(i, self.m.get(i + 1)!!);
//         i += 1;
//     }

//     self.m.set(self.length - 1, null); // delete the last entry
//     self.length -= 1; // decrease the length field

//     return memorized;
// }

// // Extension mutation function for deleting the last entry and returning its value
// extends fun deleteLast(self: Array): Address {
//     require(self.length > 0, "No items in the array!");

//     // Note that we use the !! operator, as we know for sure the value would be there
//     let lastItem = self.m.get(self.length - 1)!!;
//     self.m.set(self.length - 1, null); // delete the entry
//     self.length -= 1; // decrease the length field

//     return lastItem;
// }

// // Extension function for deleting all items in the Array
// extends mutates fun deleteAll(self: Array) {
//     self.m = emptyMap();
//     self.length = 0;
// }

// // Global static function for creating an empty Array
// fun emptyArray(): Array {
//     return Array { m: emptyMap(), length: 0 }; // length defaults to 0
// }

// // Contract emulating an Array using the map
// contract MapAsArray {
//     // Persistent state variables
//     array: Array;

//     // Constructor (initialization) function of the contract
//     init() {
//         self.array = emptyArray();
//     }

//     // Internal message receiver, which responds to a `null` message body
//     // If used for deployment, forwards the remaining value back to the sender
//     receive() { cashback(sender()) }

//     // Internal message receiver, which responds to a String message "append"
//     receive("append") {
//         // Add a new item
//         self.array.append(42);
//     }

//     // Internal message receiver, which responds to a String message "delete_5th"
//     receive("delete_5th") {
//         // Remove the 5th item if it exists and reply back with its value, or raise an error
//         self.reply(self.array.deleteIdx(4).toCoinsString().asComment()); // index offset 0 + 4 gives the 5th item
//     }

//     // Internal message receiver, which responds to a String message "del_last"
//     receive("del_last") {
//         // Remove the last item and reply back with its value, or raise an error
//         self.reply(self.array.deleteLast().toCoinsString().asComment());
//     }

//     // Internal message receiver, which responds to a String message "get_last"
//     receive("get_last") {
//         // Reply back with the latest item in the array if it exists, or raise an error
//         self.reply(self.array.getLast().toCoinsString().asComment());
//     }

//     // Internal message receiver, which responds to a String message "delete_all"
//     receive("delete_all") {
//         self.array.deleteAll();
//     }
//}

// Event with optimized data packing
// message(0x16) NetworkEvent {
//     eventType: Int as uint8;
//     from: Address;
//     to: Address;
//     amount: Int as coins;
// }

struct FriendsAndFollowings {
    friends: map<Address, Int as uint12>;
    followings: map<Address, Int as uint12>;
}

struct InvitorNominee {
    invitor: Address?;
    nominee: Address?;
}

struct JettonData {
    totalSupply: Int;
    mintable: Bool;
    owner: Address;
    content: Cell;
    jettonWalletCode: Cell;
}

struct JettonWalletData {
    balance: Int; //TODO: map of different jettons
    owner: Address;
    minter: Address; // TODO: array of different minters(maybe wallet gen isInTrouble coz of this)
    code: Cell;
}

struct MaybeAddress {
    address: Address?;
}

message(15) JettonUpdateContent {
    queryId: Int as uint64;
    content: Cell;
}

message(16) JettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address?;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(17) JettonTransferInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
// TODO: sent but received : maybe sent to app and not contract
message(18) JettonNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    forwardPayload: Slice as remaining;
}

message(19) JettonBurn {
    queryId: Int as uint64;
    amount: Int as coins;
    responseDestination: Address?;
    customPayload: Cell?;
}

message(20) JettonBurnNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
}

message(21) JettonExcesses {
    queryId: Int as uint64;
}

message(22) ProvideWalletAddress {
    queryId: Int as uint64;
    ownerAddress: Address;
    includeAddress: Bool;
}

message(23) TakeWalletAddress {
    queryId: Int as uint64;
    walletAddress: Address;
    ownerAddress: Cell?; //It is Maybe ^Address, just encoded it like this
}

message(24) Mint {
    queryId: Int as uint64;
    receiver: Address;
    mintMessage: JettonTransferInternal;
}

message(25) Mintable {
    mintable: Bool;
}

message(26) CloseMinting {}

message(27) ChangeOwner {
    queryId: Int as uint64;
    newOwner: Address;
}

// provide_wallet_balance#7ac8d559 receiver:MsgAddress include_verify_info:Bool = InternalMsgBody
message(28) ProvideWalletBalance {
    receiver: Address;
    includeVerifyInfo: Bool;
}

struct VerifyInfo {
    owner: Address;
    minter: Address;
    code: Cell;
}

// verify_info$_ owner:MsgAddress minter:MsgAddress code:^Cell = VerifyInfo
// take_wallet_balance#ca77fdc2 balance:Coins verify_info:(Maybe VerifyInfo) = InternalMsgBody
message(29) TakeWalletBalance {
    balance: Int as coins;
    verifyInfo: VerifyInfo?;
}

// claim_ton#0393b1ce receiver:MsgAddress = InternalMsgBody
message(30) ClaimTON {
    receiver: Address;
}

message(31) UnfriendInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
message(32) ReInviteInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
message(34) UnInviteInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
message(33) U {
    op: Int as uint6;
    amount: Int? as coins;
    sender: Address?;
    receiver: Address?;
    forwardPayload: Slice as remaining;
}
message(35) AccCloseBurnInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}
