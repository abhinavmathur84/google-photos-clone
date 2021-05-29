import UIKit

var greeting = "Hello, playground"

var dict = [Int:Int]()

for i in 12...1000 {
    dict[i]=i
}

print(dict.count)
for i in 0...10 {
    dict.removeValue(forKey: i)
    print(dict.count)
}



