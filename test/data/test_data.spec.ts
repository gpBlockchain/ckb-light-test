import {genTestData, getTestDataByFile, writeTestData} from "./test_data";

import * as fs from "fs";
import {BI} from "@ckb-lumos/bi";
import {waitScriptsUpdate} from "../../service/lightService";

describe('test data', function () {
    this.timeout(100000000)

    it("dd",async ()=>{
        await waitScriptsUpdate(BI.from("999999999"))
    })

    it.skip('get test data', async () => {
        // let height =BI.from((await getTipHeader(CKB_RPC_URL)).number).toNumber()
        let height = 1600000
        const step = 5000
        const batch = 10
        for (let i = 1550000; i < height; i += step * batch) {
            let batchScript = []
            for (let j = 0; j < batch; j++) {
                batchScript.push(genTestData(i + step * j, i + step * (j + 1)))
            }
            for (let j = 0; j < batchScript.length; j++) {
                let td = await batchScript[j]
                writeTestData(td, "resource/test-" + (i + step * j) + "-" + (i + step * (j + 1)) + ".json")
                console.log('write succ:', "resource/test-" + (i + step * j) + "-" + (i + step * (j + 1)) + ".json")
            }
        }
    })
    it('getTestMsg', async () => {
        let files = getTestDataPath()
        files.forEach(file => {
            let td = getTestDataByFile(file)
            console.log(
                " file_name:", file,
                " script_type_total:", td.script_type_total,
                " script_data_total:", td.script_data_total,
                " script_data1_total:", td.script_data1_total)

        })
    })


});

function getTestDataPath(): string[] {
    return fs.readdirSync("resource").map(file => "resource/" + file)
}
