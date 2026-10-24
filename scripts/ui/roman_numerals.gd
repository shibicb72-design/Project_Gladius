class_name RomanNumerals
extends RefCounted
## Pure integer to Roman numeral conversion for HUD scores (OQ-38).

## Zero (or negative) has no Roman numeral; "N" (nulla) is the placeholder, see OQ-38.
const ZERO_TEXT := "N"

const _VALUES: Array[int] = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
const _SYMBOLS: Array[String] = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]


static func to_roman(value: int) -> String:
	if value <= 0:
		return ZERO_TEXT
	var n := value
	var out := ""
	for i in _VALUES.size():
		while n >= _VALUES[i]:
			out += _SYMBOLS[i]
			n -= _VALUES[i]
	return out
