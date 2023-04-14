/**
 * Left pad 2-digit numbers
 */
function leftpad2(str) {
    if (str.length === 1) str = "0" + str
    return str
}

/**
 * Get the current date time in the format we want for the test database.
 * For example, 3:22 PM on June 13, 2022: 2022-06-13-15-22
 */
function getNowString() {
    const d = new Date()
    const yyyy = "" + d.getFullYear()
    let mm = leftpad2("" + (d.getMonth() + 1))
    let dd = leftpad2(d.getDay() + "")
    let HH = leftpad2(d.getHours() + "")
    let min = leftpad2(d.getMinutes() + "")
    let sec = leftpad2(d.getSeconds() + "")
    return `${yyyy}_${mm}_${dd}_${HH}_${min}_${sec}`
}

module.exports = { leftpad2, getNowString }

