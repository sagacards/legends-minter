# Legends Minter

>    Minting NFTs based on ICP transactions, entirely onchain.

The goal is to allow an individual to send ICP to us, and based on the completion of that transaction we will mint an NFT to their principal. Additionally, we may wish to refund that transfer under certain conditions, such as when there are no more NFTs left to mint. To achieve this, we need access to onchain transaction data.

There are some caveats to the approach that we will be using, which I will mention from the outset. First, completing the transaction will require the user to make two calls to the ledger canister. We can simplify this within our frontend application by performing these calls in an automatic sequence, but if a user is making these calls another way they will have to take this into account. Second, there's nothing stopping a user from sending us a transaction from a principal that does not support NFTs, which could result in an NFT being minted into a "blackhole." Recovery from such an event should not be impossible, however, and we can explore that recovery later on.

For the first milestone in this exercise, we will create a canister which authorizes the completion of a transaction from a user's principal to our destination principal. For now the only simply listing these other functionality that we will provide is a way to list out those authorized transactions. In the future we can extend this to add minting an NFT based on an authorized transaction. We will also  make calls to the ledger canister directly for now, instead of building out a frontend to complete the transaction.

## How It Works

We rely on two methods on the Internet Computer's official ledger canister: `send_dfx` and `notify_dfx`. It should be noted that relying on these methods is [explicitly discouraged in the source code](https://github.com/dfinity/ic/blob/c58c75a687621530b2635b22630e9562424fa3b3/rs/rosetta-api/ledger_canister/src/main.rs#L514). They are apparently likely to break in the future, and the protobuff versions of these same methods are to be preferred. Perhaps there is a Motoko protobuff implementation which would allow us to proceed on that recommended path, but for the time being we will rely on these methods.

- [ ] TODO: Assess eventuality of backwards incompatible changes to `send_dfx` and `notify_dfx`.

As well as the official ICP Ledger Canister, we will also be developing our own Transaction Authenticator Canister (which we will call TxAuth,) and we will need a wallet which will receive the funds of each transaction.

The logical flow on the blockchain is fairly straightforward.

1. User calls `send_dfx(memo, amount, fee, from_subaccount, to, created_at_time)` on Ledger to send ICP to our receiving canister (we'll break down the parameters of that function call shortly.)
2. User calls `notify_dfx(block_height, max_fee, from_subaccount, to_canister, to_subaccount)`.
3. TxAuth receives the notification from Ledger that was created by our `notify_dfx` call. We validate the data we are receiving from the Ledger, and add it to our list of authenticated transactions.

Seems easy enough, right? Let's start building!!

## Testing Using CLI

First, let's try just sending some ICP between principals using the `send_dfx` method. Thanks to Moritz, we can read [this helpful article all about interacting with the IC via CLI](https://ic.associates/nns-command-line-guide/).

Here's the bit we're interested in:

```
❯ dfx canister --network ic --no-wallet call ryjl3-tyaaa-aaaaa-aaaba-cai send_dfx \
'(
    record { 
        memo = 1 : nat64; 
        amount = record {e8s = <AMOUNT_TO_SEND> : nat64}; 
        fee = record {e8s = 10_000 : nat64}; 
        to =  "<DESTINATION_ADDRESS>"
    }
)'
```

The `to` field should be in the address format, not the principal format. For our amount, we can simply send 1. We will now use dfx to send ICP from one of our accounts to another using this method. You can manage these identities using the `dfx identity`, which I won't cover. We are not so concerned with the memo parameter for the time being, but it is required, so we'll just give it any old value for now.

```
❯ dfx canister --network ic --no-wallet call ryjl3-tyaaa-aaaaa-aaaba-cai send_dfx \
'(
    record { 
        memo = 1 : nat64; 
        amount = record {e8s = 1 : nat64}; 
        fee = record {e8s = 10_000 : nat64}; 
        to =  "<IDENTITY_#2_ADDRESS>";
    }
)'
(1_262_859 : nat64)
```

The response that we received is the blockheight where our transaction was completed (`1_262_859`). Take note, because we'll need that to trigger our notification.

If we now switch to our second identity, we can see our updated balance!

```
❯ dfx ledger --network ic balance
0.00000001 ICP
```

The next step would be to trigger a notification, but we can't really do that until our TxAuth  Canister is up and ready to receive it! However, we can look at what that call would be in dfx:

```
❯ dfx canister --network ic --no-wallet call ryjl3-tyaaa-aaaaa-aaaba-cai notify_dfx \
'(
    record { 
        block_height = 1_262_859 : nat64;
        max_fee = record {e8s = 10_000 : nat64};
        to_canister = principal "CANISTER-ID-IN-PRINCIPAL-FORMAT";
    }
)'
```

If we run this now, we will see the following error: `Notification failed with message 'Canister <...> does not exist'`. So, let's get started on our TxAuth canister!

## Building The TxAuth Canister

_Because we are going to be relying on the real IC ledger canister (`ryjl3-tyaaa-aaaaa-aaaba-cai`), we'll build directly on Mainnet._

We can see in the [source code](https://github.com/dfinity/ic/blob/c58c75a687621530b2635b22630e9562424fa3b3/rs/rosetta-api/ledger_canister/src/main.rs#L296) that Ledger's `notify_dfx` method will call `transaction_notification` on our TxAuth Can. All we want to do is capture the message from the Ledger notification, and push a record into our list of authenticated transactions.

The first thing we need to do is determine the type of data that we will be receiving from the Ledger and storing in our TxAuth Canister. We can pull this from [source](https://github.com/dfinity/ic/blob/779549eccfcf61ac702dfc2ee6d76ffdc2db1f7f/rs/rosetta-api/ledger_canister/src/lib.rs#L1669). The rest of the types we can pull from the [candid interface](https://ic.rocks/interfaces/nns/ledger.did).

```
type CanisterId = Principal;
type BlockHeight = Nat64;
type Memo = Nat64;
type SubAccount = [Nat8];
type ICPTs = {
    e8s : Nat64;
};

type TransactionNotification = {
    from: Principal;
    from_subaccount: ?SubAccount;
    to: CanisterId;
    to_subaccount: ?SubAccount;
    block_height: BlockHeight;
    amount: ICPTs;
    memo: Memo;
};
```

Next, we'll need to define some state to capture transactions and persist them between canister upgrades.

```
var stableTransactions : [TransactionNotification] = [];
let transactions = Buffer.Buffer<TransactionNotification>(stableTransactions.size());

// Provision transactions from stable memory
for (v in stableTransactions.vals()) {
    transactions.add(v);
};

system func preupgrade () {
    // Preserve transactions before upgrades
    stableTransactions := transactions.toArray();
};
```

Next up, we'll create the method to receive notifications from the Ledger.

```
public shared ({ caller }) func transaction_notification (args : TransactionNotification) : async () {

    // We need to make sure that only the Ledger can call this endpoint
    let ledger = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
    assert(caller == ledger);

    transactions.add(args);

};
```

The last thing we need is a method to read the state of our authenticated transactions.

```
public query func readTransactions () : async ([TransactionNotification]) {
    transactions.toArray();
}
```

See [main.mo](src/main.mo) for complete canister code.

With that in place, we can deploy our TxAuth canister to Mainnet.

```
❯ dfx deploy --network ic
```

And now we can use `notify_dfx` to send the transaction from the Ledger to our new TxAuth canister!

## Putting It All Together

Unfortunately, there appears to be a limitation on only the recipient of a transaction being able to be notified of that transaction. I must be missing something 🤔.

Still, if I send ICP to my canister principal, I can notify it and read out the authenticated transaction:

```
❯ dfx canister --network ic --no-wallet call ryjl3-tyaaa-aaaaa-aaaba-cai send_dfx \
'(
    record {
        memo = 1 : nat64;
        amount = record {e8s = 1 : nat64};
        fee = record {e8s = 10_000 : nat64};
        to =  "fecf37d8f227ad6bd02f259794c3414080fd6f4ac2a9ef49ccb3dea1bd3ad01a"
    }
)'
(1_263_850 : nat64)
```

```
❯ dfx canister --network ic --no-wallet call ryjl3-tyaaa-aaaaa-aaaba-cai notify_dfx \
'(
    record {
        block_height = 1_263_850 : nat64;
        max_fee = record {e8s = 10_000 : nat64};
        to_canister = principal "lykvf-5qaaa-aaaaj-qaimq-cai";
    }
)'
()
```

```
❯ dfx canister --network ic call minter readTransactions
(
  vec {
    record {
      to = principal "lykvf-5qaaa-aaaaj-qaimq-cai";
      to_subaccount = null;
      from = principal "k2syn-nenrg-67lse-cn2pm-srhsr-c3rsj-tfatg-63ga5-pz25g-x56ob-2ae";
      memo = 1 : nat64;
      from_subaccount = null;
      amount = record { e8s = 1 : nat64 };
      block_height = 1_263_850 : nat64;
    };
  },
)
````