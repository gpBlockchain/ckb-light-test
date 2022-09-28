import {
    Address,
    BI,
    Cell,
    commons,
    config,
    core,
    hd,
    helpers,
    Indexer,
    RPC,
    Script,
    toolkit,
    WitnessArgs,
} from "@ckb-lumos/lumos";
import {values} from "@ckb-lumos/base";
import {ANY_ONE_CAN_PAY, ANY_ONE_CAN_PAY_TYPE_ID, FEE, FeeRate} from "../config/config";
import {DepType} from "@ckb-lumos/base/lib/api";

const { ScriptValue } = values;

export const { AGGRON4 } = config.predefined;



const CKB_RPC_URL = "https://testnet.ckb.dev/rpc";
const CKB_INDEXER_URL = "https://testnet.ckb.dev/indexer";
const rpc = new RPC(CKB_RPC_URL);
const indexer = new Indexer(CKB_INDEXER_URL, CKB_RPC_URL);

type Account = {
    lockScript: Script;
    address: Address;
    pubKey: string;
};
export const generateAccountFromPrivateKey = (privKey: string): Account => {
    const pubKey = hd.key.privateToPublic(privKey);
    const args = hd.key.publicKeyToBlake160(pubKey);
    const template = AGGRON4.SCRIPTS.SECP256K1_BLAKE160!;
    const lockScript = {
        code_hash: template.CODE_HASH,
        hash_type: template.HASH_TYPE,
        args: args,
    };
    const address = helpers.generateAddress(lockScript, { config: AGGRON4 });
    return {
        lockScript,
        address,
        pubKey,
    };
};

export async function capacityOf(address: string): Promise<BI> {
    const collector = indexer.collector({
        lock: helpers.parseAddress(address, { config: AGGRON4 }),
    });

    let balance = BI.from(0);
    for await (const cell of collector.collect()) {
        balance = balance.add(cell.cell_output.capacity);
    }

    return balance;
}

interface transferOptions {
    from: string;
    to: string;
    amount: string;
    privKey: string;
}
interface Options {
    from: string;
    outputCells: Cell[];
    privKey: string;
    inputCells?: Cell[];
    deps?:[];
}

function getOutPutCell(to:string,amount: string,data:string):Cell{

    const toScript = helpers.parseAddress(to, { config: AGGRON4 });
    return {
        cell_output: {
            capacity: BI.from(amount).mul(100000000).toHexString(),
            lock: toScript,
        },
        data: "0x",
    };
}

export async function transfer(options: transferOptions): Promise<string> {

    const transferOutput: Cell = getOutPutCell(options.to,options.amount,"0x");
    return send_tx({
        from:options.from,
        outputCells:[transferOutput],
        privKey:options.privKey,
    });
}

export async function send_tx_with_input(options:Options):Promise<string>{
    let txSkeleton = helpers.TransactionSkeleton({});

    const fromScript = helpers.parseAddress(options.from, { config: AGGRON4 });


    txSkeleton = txSkeleton.update("inputs", (inputs) => inputs.push(...options.inputCells));
    txSkeleton = txSkeleton.update("outputs", (outputs) => outputs.push(...options.outputCells));
    txSkeleton = txSkeleton.update("cellDeps", (cellDeps) =>

        cellDeps.push(...[
            {
                out_point: {
                    tx_hash: AGGRON4.SCRIPTS.SECP256K1_BLAKE160.TX_HASH,
                    index: AGGRON4.SCRIPTS.SECP256K1_BLAKE160.INDEX,
                },
                dep_type: AGGRON4.SCRIPTS.SECP256K1_BLAKE160.DEP_TYPE,
            },{
                out_point: {
                    tx_hash: AGGRON4.SCRIPTS.SUDT.TX_HASH,
                    index: AGGRON4.SCRIPTS.SUDT.INDEX,
                },
                dep_type: AGGRON4.SCRIPTS.SUDT.DEP_TYPE,
            },
            {
                out_point: {
                    tx_hash: ANY_ONE_CAN_PAY.TX_HASH,
                    index: ANY_ONE_CAN_PAY.INDEX,
                },
                dep_type:  AGGRON4.SCRIPTS.SUDT.DEP_TYPE,
            }
            //     {
            //     out_point: {
            //         tx_hash: ANY_ONE_CAN_PAY.TX_HASH,
            //         index: ANY_ONE_CAN_PAY.INDEX,
            //     },
            //     dep_type: "code",
            // }
        ])

    );
    // txSkeleton = txSkeleton.update("cellDeps", (cellDeps) =>
    //     cellDeps.push()
    // );

    const firstIndex = txSkeleton
        .get("inputs")
        .findIndex((input) =>
            new ScriptValue(input.cell_output.lock, { validate: false }).equals(
                new ScriptValue(fromScript, { validate: false })
            )
        );
    if (firstIndex !== -1) {
        while (firstIndex >= txSkeleton.get("witnesses").size) {
            txSkeleton = txSkeleton.update("witnesses", (witnesses) => witnesses.push("0x"));
        }
        let witness: string = txSkeleton.get("witnesses").get(firstIndex)!;
        const newWitnessArgs: WitnessArgs = {
            /* 65-byte zeros in hex */
            lock:
                "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        };
        if (witness !== "0x") {
            const witnessArgs = new core.WitnessArgs(new toolkit.Reader(witness));
            const lock = witnessArgs.getLock();
            if (lock.hasValue() && new toolkit.Reader(lock.value().raw()).serializeJson() !== newWitnessArgs.lock) {
                throw new Error("Lock field in first witness is set aside for signature!");
            }
            const inputType = witnessArgs.getInputType();
            if (inputType.hasValue()) {
                newWitnessArgs.input_type = new toolkit.Reader(inputType.value().raw()).serializeJson();
            }
            const outputType = witnessArgs.getOutputType();
            if (outputType.hasValue()) {
                newWitnessArgs.output_type = new toolkit.Reader(outputType.value().raw()).serializeJson();
            }
        }
        witness = new toolkit.Reader(
            core.SerializeWitnessArgs(toolkit.normalizers.NormalizeWitnessArgs(newWitnessArgs))
        ).serializeJson();
        txSkeleton = txSkeleton.update("witnesses", (witnesses) => witnesses.set(firstIndex, witness));
    }

    txSkeleton = commons.common.prepareSigningEntries(txSkeleton);
    const message = txSkeleton.get("signingEntries").get(0)?.message;
    const Sig = hd.key.signRecoverable(message!, options.privKey);
    const tx = helpers.sealTransaction(txSkeleton, [Sig]);
    const hash = await rpc.send_transaction(tx, "passthrough");
    console.log("The transaction hash is", hash);

    return hash;
}



export async function send_tx(options: Options): Promise<string> {
    let txSkeleton = helpers.TransactionSkeleton({});
    const fromScript = helpers.parseAddress(options.from, { config: AGGRON4 });
    // const toScript = helpers.parseAddress(options.to, { config: AGGRON4 });

    // additional 0.001 ckb for tx fee
    // the tx fee could calculated by tx size
    // this is just a simple example
    let neededCapacity = BI.from(0)
    for (let i = 0; i < options.outputCells.length; i++) {
        neededCapacity = neededCapacity.add(options.outputCells[i].cell_output.capacity)
    }
    let collectedSum = BI.from(0);
    const collected: Cell[] = [];
    const collector = indexer.collector({ lock: fromScript, type: "empty" });
    for await (const cell of collector.collect()) {
        collectedSum = collectedSum.add(cell.cell_output.capacity);
        collected.push(cell);
        if (collectedSum >= neededCapacity) break;
    }
    console.log('total cell balance: ',collectedSum.toString())

    if (collectedSum < neededCapacity) {
        throw new Error("Not enough CKB");
    }

    const changeOutput: Cell = {
        cell_output: {
            capacity: collectedSum.sub(neededCapacity).sub(FeeRate.NORMAL).toHexString(),
            lock: fromScript,
        },
        data: "0x",
    };

    txSkeleton = txSkeleton.update("inputs", (inputs) => inputs.push(...collected));
    txSkeleton = txSkeleton.update("outputs", (outputs) => outputs.push(...options.outputCells, changeOutput));
    txSkeleton = txSkeleton.update("cellDeps", (cellDeps) =>
        cellDeps.push(...[
            {
            out_point: {
                tx_hash: AGGRON4.SCRIPTS.SECP256K1_BLAKE160.TX_HASH,
                index: AGGRON4.SCRIPTS.SECP256K1_BLAKE160.INDEX,
            },
            dep_type: AGGRON4.SCRIPTS.SECP256K1_BLAKE160.DEP_TYPE,
        },{
            out_point: {
                tx_hash: AGGRON4.SCRIPTS.SUDT.TX_HASH,
                index: AGGRON4.SCRIPTS.SUDT.INDEX,
            },
            dep_type: AGGRON4.SCRIPTS.SUDT.DEP_TYPE,
        },
            {
                out_point: {
                    tx_hash: ANY_ONE_CAN_PAY_TYPE_ID.TX_HASH,
                    index: ANY_ONE_CAN_PAY_TYPE_ID.INDEX,
                },
                dep_type:  AGGRON4.SCRIPTS.SUDT.DEP_TYPE,
            }
        //     {
        //     out_point: {
        //         tx_hash: ANY_ONE_CAN_PAY.TX_HASH,
        //         index: ANY_ONE_CAN_PAY.INDEX,
        //     },
        //     dep_type: "code",
        // }
        ])
    );
    txSkeleton = txSkeleton.update("cellDeps",(cellDeps)=> cellDeps.push(...options.deps));

    const firstIndex = txSkeleton
        .get("inputs")
        .findIndex((input) =>
            new ScriptValue(input.cell_output.lock, { validate: false }).equals(
                new ScriptValue(fromScript, { validate: false })
            )
        );
    if (firstIndex !== -1) {
        while (firstIndex >= txSkeleton.get("witnesses").size) {
            txSkeleton = txSkeleton.update("witnesses", (witnesses) => witnesses.push("0x"));
        }
        let witness: string = txSkeleton.get("witnesses").get(firstIndex)!;
        const newWitnessArgs: WitnessArgs = {
            /* 65-byte zeros in hex */
            lock:
                "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        };
        if (witness !== "0x") {
            const witnessArgs = new core.WitnessArgs(new toolkit.Reader(witness));
            const lock = witnessArgs.getLock();
            if (lock.hasValue() && new toolkit.Reader(lock.value().raw()).serializeJson() !== newWitnessArgs.lock) {
                throw new Error("Lock field in first witness is set aside for signature!");
            }
            const inputType = witnessArgs.getInputType();
            if (inputType.hasValue()) {
                newWitnessArgs.input_type = new toolkit.Reader(inputType.value().raw()).serializeJson();
            }
            const outputType = witnessArgs.getOutputType();
            if (outputType.hasValue()) {
                newWitnessArgs.output_type = new toolkit.Reader(outputType.value().raw()).serializeJson();
            }
        }
        witness = new toolkit.Reader(
            core.SerializeWitnessArgs(toolkit.normalizers.NormalizeWitnessArgs(newWitnessArgs))
        ).serializeJson();
        txSkeleton = txSkeleton.update("witnesses", (witnesses) => witnesses.set(firstIndex, witness));
    }

    txSkeleton = commons.common.prepareSigningEntries(txSkeleton);
    const message = txSkeleton.get("signingEntries").get(0)?.message;
    const Sig = hd.key.signRecoverable(message!, options.privKey);
    const tx = helpers.sealTransaction(txSkeleton, [Sig]);
    const hash = await rpc.send_transaction(tx, "passthrough");
    console.log("The transaction hash is", hash);

    return hash;

}
