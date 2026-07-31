class_name MouseClass
extends RefCounted
## Which of the four a mouse is (GDD section 4).
##
## IDENTITY ONLY, FOR NOW. The classes are M4 -- the Engineer's digging, the Bruiser's collapse,
## the Scout's sonar, and the stat spreads that make them different mice. None of that is here.
## What is here is the NAME, because the HUD has to say what you are playing and what your crew
## mates are playing, and a roster that reads "MOUSE" four times teaches nothing.
##
## So every mouse is a Generalist today, and that is not a placeholder -- it is true. There is
## one stat block, one speed, one carry penalty, and the Generalist is the class those numbers
## describe (balanced, and the one who runs the flag). When M4 lands, the stats arrive on top of
## a field the UI already reads rather than alongside a second way of saying the same thing.
##
## Kept as static functions on a RefCounted, exactly like team.gd, and for the same reason:
## there is no state here, and an autoload would invite someone to start keeping the match in it.

enum { GENERALIST, BRUISER, ENGINEER, SCOUT }

const NAMES: Array[String] = ["GENERALIST", "BRUISER", "ENGINEER", "SCOUT"]
## Three letters, for a roster row that has a health bar to fit on it as well.
const TAGS: Array[String] = ["GEN", "BRU", "ENG", "SCT"]


static func name_of(kind: int) -> String:
	return NAMES[clampi(kind, 0, NAMES.size() - 1)]


static func tag_of(kind: int) -> String:
	return TAGS[clampi(kind, 0, TAGS.size() - 1)]
