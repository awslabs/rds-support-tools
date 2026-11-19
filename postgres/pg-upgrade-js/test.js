const { leftpad2, getNowString } = require("./helpers")

function test(name, f) {
    try {
        const result = f()
        if (result === false) throw Error()
    } catch (ex) {
        console.error("FAILED:", name)
        return
    }
    console.log("SUCCESS:", name)
}

function assertEqual(a, b) {
    if (a != b) {
        console.error(`${a} != ${b}`)
        throw Error()
    }
    return true
}

test("leftpad2 works", function() {
    assertEqual("00", leftpad2("0"))
    assertEqual("00", leftpad2("00"))
})

test("getNowString format ok", function() {
    const re = new RegExp("^\\d\\d\\d\\d_\\d\\d_\\d\\d_\\d\\d_\\d\\d_\\d\\d$")
    let str
    try {
        str = getNowString()
    } catch (ex) {
        console.error(ex)
        return false
    }
    if (!re.test(str)) {
        throw Error()
    }
})

//console.log("d", getNowString())
//console.log("leftpad2", leftpad2("0"))
//console.log("leftpad2", leftpad2("00"))
