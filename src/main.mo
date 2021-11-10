import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";

actor {


    ////////////
    // Types //
    //////////


    type CanisterId = Principal;
    type BlockHeight = Nat64;
    type Memo = Nat64;
    type SubAccount = [Nat8];
    type ICPTs = {
        e8s : Nat64;
    };

    type NotifyCanisterArgs = {
        block_height: BlockHeight;
        max_fee: ICPTs;
        from_subaccount: ?SubAccount;
        to_canister: Principal;
        to_subaccount: ?SubAccount;
    };

    ////////////
    // State //
    //////////


    var stableTransactions : [NotifyCanisterArgs] = [];
    let transactions = Buffer.Buffer<NotifyCanisterArgs>(stableTransactions.size());

    // Provision transactions from stable memory
    for (v in stableTransactions.vals()) {
        transactions.add(v);
    };

    system func preupgrade () {
        // Preserve transactions before upgrades
        stableTransactions := transactions.toArray();
    };


    //////////
    // API //
    ////////


    public shared ({ caller }) func transaction_notification (args : NotifyCanisterArgs) : async () {

        // We need to make sure that only the Ledger can call this endpoint
        let ledger = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
        assert(caller == ledger);

        transactions.add(args);

    };


    public query func readTransactions () : async ([NotifyCanisterArgs]) {
        transactions.toArray();
    }

};
