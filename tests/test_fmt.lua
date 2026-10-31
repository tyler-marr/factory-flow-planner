local fmt = require("scripts.fmt")
for _, v in ipairs({0, 1/60, 0.5, 1, 1.5, 2.25, 10/6, 100, 1000, 25000}) do print(v, fmt.rate(v)) end
print(fmt.power(150000), fmt.power(2.5e6), fmt.parse("1,5"), fmt.parse("-1"), fmt.parse("abc"), fmt.count(2/3))
