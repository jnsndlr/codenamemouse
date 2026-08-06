class_name MouseClass
extends RefCounted
## Which of the four a mouse is (GDD section 4), and where the numbers behind that live.
##
## THE ENUM IS THE CURRENCY, the resource is the detail. Everything that has to say "what are
## you" -- the roster, the swap point, the director filling a seat -- passes one of these four
## integers around, because an integer is trivially serialisable (M7 has to send it over a wire)
## and because a system that only wants to print "ENGINEER" should not have to hold a Resource to
## do it. `definition_of` is the one place the two are joined.
##
## Preloaded rather than loaded on demand. Four small resources, wanted the instant a mouse
## enters the tree, and a class switch is not the moment to touch a disk.
##
## Kept as static functions on a RefCounted, exactly like team.gd, and for the same reason:
## there is no state here, and an autoload would invite someone to start keeping the match in it.

## The order is the order they appear on the swap bar and the order C cycles through, so it is
## a presentation decision as much as a data one: Generalist first because it is the on-ramp,
## then the two specialists you pick on purpose, then the Brute at the end.
enum { GENERALIST, ENGINEER, SNEAK, BRUTE }

const DEFINITIONS: Array[ClassDefinition] = [
	preload("res://resources/classes/generalist.tres"),
	preload("res://resources/classes/engineer.tres"),
	preload("res://resources/classes/sneak.tres"),
	preload("res://resources/classes/brute.tres"),
]

## How many the swap point walks through.
##
## All four are pickable. The Engineer, Sneak and Brute have their defining map-control abilities
## -- the barricade, sonar, and the cave-in in both its forms. Second Wind, Fade and Slam remain
## later work.
const COUNT: int = 4


static func definition_of(kind: int) -> ClassDefinition:
	return DEFINITIONS[clampi(kind, 0, DEFINITIONS.size() - 1)]


static func name_of(kind: int) -> String:
	return definition_of(kind).display_name


## Three letters, for a roster row that has a health bar to fit on it as well.
static func tag_of(kind: int) -> String:
	return definition_of(kind).tag


## The next class round the wheel. One key at the swap point rather than four, because at your
## own nest you are stationary and safe, and the only price the GDD wants a switch to carry is
## the walk home (section 4) -- not a keypad to memorise.
static func next(kind: int) -> int:
	return (kind + 1) % COUNT
