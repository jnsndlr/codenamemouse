class_name Breakable
extends Node3D
## Something in the world a swing can take apart: a barricade wedged across a corridor, a boulder
## lying on the lawn, and the branches and sticks that come after them.
##
## ONE INTERFACE, because "can I hit this" is a question the mouse should only have to ask one way.
## Before this there was a second swing pass written specifically against barricades, and adding
## boulders to it would have meant a third -- at which point every new destructible thing costs an
## edit to `mouse.gd`, and the one most likely to be forgotten is the one that makes it hittable.
## The swing now walks this group and asks each thing whether it broke.
##
## THE HIT POOL IS PER OBJECT, not per material or per class. A boulder that covers four tiles is
## four of these standing shoulder to shoulder, so it takes four times the work to clear and can be
## opened a quarter at a time -- which is a decision (do I want the whole rock gone, or just a way
## past it?) rather than a single long countdown.
##
## NOT A HEALTH BAR. Hits are counted, not damage: a swing either lands or it doesn't, and how hard
## the swinger hits has nothing to do with it. Rock does not care how strong you are, it cares
## whether you are the one built for shifting rock -- which is the whole of `_may_break`.
##
## DO NOT REDECLARE A CONSTANT A SUBCLASS ALREADY DECLARES, in either direction. A subclass with
## its own `const GROUP` shadowing the one below does not warn and does not fail where you wrote
## it: every OTHER file that reads `Subclass.GROUP` fails to parse with "Could not resolve external
## class member", which reads exactly like a cyclic-dependency error and sent an hour looking for
## one. `BarricadeRock` keeps its own group under a different name for this reason.

## Broken, and by whom. The `by` is for the feed and for anything later that counts who did what.
signal broken(what: Breakable, by: Mouse)

const GROUP: StringName = &"breakable"

## Swings to take it apart.
@export var hits_to_clear: int = 3
## Which class may. An export rather than a hard-coded check, because "who shifts rock" is a design
## question and this project's answers have moved before.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var breaker_class: int = MouseClass.BRUTE

## Which layer this stands on, so a swing from another plane cannot reach it. 0 is the lawn.
var plane: int = 0

var _left: int = 0


func _ready() -> void:
	add_to_group(GROUP)
	_left = hits_to_clear


## Swings still to come. For the audits, which cannot tell "the swing missed" from "the swing was
## ignored" by looking at whether the thing is still standing -- with five hits, four of the five
## interesting failures leave it there either way.
func hits_left() -> int:
	return _left


## A swing landed. Returns whether it did anything, so the caller can explain a swing that didn't.
func hit_by(who: Mouse) -> bool:
	if who == null or not _may_break(who):
		return false
	# Already gone. `queue_free` is deferred, so two Brutes swinging on the same frame both find
	# this alive -- and without the guard the second one drives the count negative and breaks the
	# same rock twice, which is two bursts of debris and one very confused audit.
	if _left <= 0:
		return false
	_left -= 1
	if _left > 0:
		_on_damaged()
		return true
	_on_broken(who)
	broken.emit(self, who)
	return true


## ONLY THE ONE CLASS (GDD section 4). It gives the Brute a job that is not fighting, and it makes
## an obstruction something the other crew answers with a class choice rather than with patience --
## which is exactly the counterplay web section 5 asks for.
func _may_break(who: Mouse) -> bool:
	return who.mouse_class == breaker_class


## Shrinks as it goes, so the last swing is visibly the last one. A health bar on a piece of
## scenery would be a HUD element for a rock.
func _on_damaged() -> void:
	scale = Vector3.ONE * (0.72 + 0.28 * float(_left) / float(maxi(hits_to_clear, 1)))


func _on_broken(_by: Mouse) -> void:
	queue_free()
