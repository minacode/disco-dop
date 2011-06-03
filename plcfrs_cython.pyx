# cython: boundscheck=False
# cython: profile=False

# probabilistic CKY parser for Simple Range Concatenation Grammars
# (equivalent to Linear Context-Free Rewriting Systems)
from math import log, exp, fsum, isinf
from random import choice, randrange
from operator import itemgetter
from itertools import islice, count
from collections import defaultdict, deque
from array import array
import re, gc
from nltk import FreqDist, Tree
from rcgrules import enumchart, induce_srcg

# sentinel node to indicate unary productions and preterminals
NONE = ChartItem(0, 0)

# to avoid overhead of __init__ and __cinit__ constructors
cdef inline Pair new_Pair(object a, object b):
	cdef Pair pair = Pair.__new__(Pair)
	pair.a = a; pair.b = b
	return pair

cdef inline ChartItem new_ChartItem(unsigned int label, unsigned long vec):
	cdef ChartItem item = ChartItem.__new__(ChartItem)
	item.label = label; item.vec = vec
	item._hash = hash((label, vec))
	return item

cdef inline Edge new_Edge(double inside, double prob, ChartItem left, ChartItem right):
	cdef Edge edge = Edge.__new__(Edge)
	edge.inside = inside; edge.prob = prob
	edge.left = left; edge.right = right
	return edge

#cdef inline tuple prune_rules(chart, unary, lbinary, rbinary):
#	""" prune rules not used in chart """

def parse(sent, grammar, tags=None, start=None, bint viterbi=False, int n=1, estimate=None, frozenset prune=frozenset(), dict prunetoid={}):
	""" parse sentence, a list of tokens, optionally with gold tags, and
	produce a chart, either exhaustive or up until the viterbi parse
	"""
	cdef list unary = grammar.unary
	cdef list lbinary = grammar.lbinary
	cdef list rbinary = grammar.rbinary
	cdef dict lexical = <dict>grammar.lexical
	cdef dict toid = <dict>grammar.toid
	cdef dict tolabel = <dict>grammar.tolabel
	cdef int m = 0, maxA = 0, x
	cdef bint doprune = False
	cdef int lensent = len(sent), label, newlabel
	#A = heapdict() #if viterbi else {}
	cdef heapdict A = heapdict()				#the agenda
	cdef dict C = <dict>defaultdict(list)		#the full chart
	cdef list Cx = [{} for _ in toid]			#the viterbi probabilities
	cdef dict removeid = {}
	#cdef list results = []						#temporary values
	cdef object results = deque()				#temporary values
	cdef Entry entry
	cdef Edge edge, newedge
	cdef ChartItem Ih, I1h, goal, newitem
	if start == None: start = toid["ROOT"]
	goal = ChartItem(start, (1 << len(sent)) - 1)
	if prune:
		doprune = True
		for a, label in toid.items():
			newlabel = prunetoid[a.split("@")[0]]
			removeid[label] = newlabel
		print 'pruning on with %d nonterminals and %d items with %d categories' % (
					len(removeid), len(prune), len(set(removeid.values())))
	gc.disable()
	# scan
	Epsilon = toid["Epsilon"]
	for i,w in enumerate(sent):
		recognized = False
		for rule in lexical.get(w, []):
			# if we are given gold tags, make sure we only allow matching
			# tags - after removing addresses introduced by the DOP reduction, 
			# and give probability of 1
			if not tags or tags[i] == tolabel[rule.lhs].split("@")[0]:
				Ih = ChartItem(rule.lhs, 1 << i)
				I = ChartItem(Epsilon, i)
				z = 0 if tags else rule.prob
				A[Ih] = Edge(rule.prob, rule.prob, I, NONE)
				recognized = True
		if not recognized and tags and tags[i] in toid:
				Ih = ChartItem(toid[tags[i]], 1 << i)
				I = ChartItem(Epsilon, i)
				A[Ih] = Edge(0, 0, I, NONE)
				recognized = True
				continue
		elif not recognized:
			print "not covered:", tags[i] if tags else w
			return C, NONE
	cdef set seen = set()
	# parsing
	while A.length:
		entry = A.popentry()
		Ih = <ChartItem>entry.key
		edge = <Edge>entry.value
		#Ihedge = A.popitem()
		#Ih.label, Ih.vec = <ChartItem>Ihedge[0].label, <ChartItem>Ihedge[1].vec
		#when heapdict is not available:
		#Ih, (x, I) = min(A.items(), key=lambda x:x[1]); del A[Ih]
		(<list>(C[Ih])).append(edge)
		(<dict>(Cx[Ih.label]))[Ih] = edge #.inside
		if Ih == goal: #Ih.label == goal.label and Ih.vec == goal.vec:
			m += 1
			if viterbi and n == m: break
			#if viterbi and not exhaustive: break
		else:
			#results = [] #del results[:]
			#results.clear()
			deduced_from(Ih, edge.inside, Cx, unary, lbinary, rbinary,
															estimate, results)
			#for pair in results:
			popleft = results.popleft
			x = len(results)
			while x:
				pair = popleft(); x -= 1
				I1h = <ChartItem>((<Pair>pair).a)
				newedge = <Edge>((<Pair>pair).b)
				if not (A.contains(I1h) or I1h in C):
					if doprune and I1h not in C:
						newitem = new_ChartItem(removeid[I1h.label], I1h.vec)
						if newitem not in prune:
								#if newitem not in seen:
								#	seen.add(newitem)
								#	print "prune %s[%s]" % (tolabel[newitem.label],
								#				binrepr(newitem, sent)) #continue
								continue						
					# haven't seen this item before, add to agenda
					A.setitem(I1h, newedge)
				elif A.contains(I1h):
					if newedge.inside < (<Edge>(A.getitem(I1h))).inside:
						# item has lower score, update agenda
						(<list>C[I1h]).append(A.replace(I1h, newedge))
					else:
						(<list>C[I1h]).append(newedge)
				else: #if not viterbi: #item is not in agenda, but is in chart
					(<list>C[I1h]).append(newedge)
					#Cx[I1h.label][I1h] = min(Cx[I1h.label][I1h], newedge.inside)
					#if newedge.inside < <double>(<dict>(Cx[I1h.label])[I1h]):
					#	(<dict>Cx[I1h.label])[I1h] = newedge.inside
		maxA = max(maxA, len(A))
	print "max agenda size %d / chart keys %d / values %d" % (
								maxA, len(C), sum(map(len, C.values()))),
	gc.enable()
	if goal in C: return C, goal
	else: return C, NONE

cdef inline void deduced_from(ChartItem Ih, double x, list Cx,
							list unary, list lbinary, list rbinary,
							object estimate, object results):
	""" Produce a list of all ChartItems that can be deduced using the
	existing items in Cx and the grammar rules. """
	cdef double y
	cdef ChartItem I1h
	cdef list rules
	cdef dict items
	cdef Rule rule
	rules = <list>unary[Ih.label]
	resultsappend = results.append
	for rule in rules:
		#(estimate(rule.lhs, Ih.vec) if estimate else 0.0) + x + rule.prob,
		resultsappend(new_Pair(
						new_ChartItem(rule.lhs, Ih.vec),
						new_Edge(x + rule.prob, rule.prob, Ih, NONE)))
	rules = <list>lbinary[Ih.label]
	for rule in rules:
		items =  <dict>(Cx[rule.rhs2])
		for I1h in items:
			if concat(rule, Ih.vec, I1h.vec):
				y = (<Edge>(items[I1h])).inside
				#(estimate(rule.lhs, Ih.vec ^ I1h.vec)
				#if estimate else 0.0) + x + y + rule.prob,
				resultsappend(new_Pair(
					new_ChartItem(rule.lhs, Ih.vec ^ I1h.vec),
					new_Edge(x + y + rule.prob, rule.prob, Ih, I1h)))
	rules = <list>rbinary[Ih.label]
	for rule in rules:
		items = <dict>(Cx[rule.rhs1])
		for I1h in items:
			if concat(rule, I1h.vec, Ih.vec):
				y = (<Edge>(items[I1h])).inside
				#((estimate(rule.lhs, I1h.vec ^ Ih.vec)
				#if estimate else 0.0) + x + y + rule.prob,
				resultsappend(new_Pair(
					new_ChartItem(rule.lhs, I1h.vec ^ Ih.vec),
					new_Edge(x + y + rule.prob, rule.prob, I1h, Ih)))

cdef inline bint concat(Rule rule, unsigned long lvec, unsigned long rvec):
	"""
	Determine the compatibility of two bitvectors (tuples of spans / ranges)
	according to the given yield function. Ranges should be non-overlapping,
	continuous when they are concatenated, and adhere to the ordering in the
	yield function.
	The yield function is a tuple of tuples with indices indicating from which
	vector the next span should be taken from, with 0 meaning left and 1 right.
	Note that the least significant bit is the lowest index in the vectors,
	which is the opposite of their normal presentation: 0b100 is the last
	terminal in a three word sentence, 0b001 is the first. E.g.,

	>>> lvec = 0b0011; rvec = 0b1000; yieldfunction = ((0,), (1,))
	>>> concat(((0,), (1,)), lvec, rvec)
	True		#discontinuous, non-overlapping, linearly ordered.
	>>> concat(((0, 1),), lvec, rvec)
	False		#lvec and rvec are not contiguous
	>>> concat(((1,), (0,)), lvec, rvec)
	False		#rvec's span should come after lvec's span
	
	update: yield functions are now encoded in binary arrays:
		( (0, 1, 0), (1, 0) ) ==> array('B', [0b010, 0b01])
							and lengths: array('B', [3, 2])
		NB: note reversal
	"""
	if lvec & rvec: return False
	cdef int lpos = nextset(lvec, 0)
	cdef int rpos = nextset(rvec, 0)
	# if there are no gaps in lvec and rvec, and the yieldfunction is the
	# concatenation of two elements, then this should be quicker
	if False and (lvec >> nextunset(lvec, lpos) == 0
		and rvec >> nextunset(rvec, rpos) == 0):
		if rule.lengths._B[0] == 2 and rule.args.length == 1:
			if rule.args._B[0] == 0b10: #yieldfunction == ((0, 1),):
				return bitminmax(lvec, rvec)
			elif rule.args._B[0] == 0b01: #yieldfunction == ((1, 0),):
				return bitminmax(rvec, lvec)
		#else:
		#	return False
	#this algorithm taken from rparse, FastYFComposer.
	cdef int n, x
	cdef unsigned char arg, m
	for x in range(rule.args.length):
		arg = rule.args._B[x]
		m = rule.lengths._B[x] - 1 #len(arg) - 1
		for n in range(m + 1): #enumerate(arg):
			if testbitc(arg, n): #bit == 1:
				# check if there are any bits left, and
				# if any bits on the right should have gone before
				# ones on this side
				if rpos == -1 or (lpos != -1 and lpos <= rpos):
					return False
				# jump to next gap
				rpos = nextunset(rvec, rpos)
				if lpos != -1 and lpos < rpos:
					return False
				# there should be a gap if and only if
				# this is the last element of this argument
				if n == m:
					if testbit(lvec, rpos):
						return False
				elif not testbit(lvec, rpos):
					return False
				#jump to next argument
				rpos = nextset(rvec, rpos)
			else: #if bit == 0:
				# vice versa to the above
				if lpos == -1 or (rpos != -1 and rpos <= lpos):
					return False
				lpos = nextunset(lvec, lpos)
				if rpos != -1 and rpos < lpos:
					return False
				if n == m:
					if testbit(rvec, lpos):
						return False
				elif not testbit(rvec, lpos):
					return False
				lpos = nextset(lvec, lpos)
			#else: raise ValueError("non-binary element in yieldfunction")
	if lpos != -1 or rpos != -1:
		return False
	# everything looks all right
	return True

def filterchart(chart, start):
	# remove all entries that do not contribute to a complete derivation headed
	# by "start"
	chart2 = {}
	filter_subtree(start, <dict>chart, chart2)
	assert start in chart2
	return chart2

cdef void filter_subtree(ChartItem start, dict chart, dict chart2):
	cdef Edge edge
	if start in chart2:
		assert chart2[start] == chart[start]
		return
	if start in chart: chart2[start] = chart[start]
	else: chart2[start] = []
	if start.label:
		for edge in chart[start]:
			filter_subtree((<Edge>edge).left, chart, chart2)
			if edge.right.label:
				filter_subtree(edge.right, chart, chart2)

def filtercycles(chart, start, visited, current):
	""" remove @#$%! cycles from chart
	FIXME: not working correctly yet. Only zero cost cycles seem to be a
	problem, though. """
	visited.add(start)
	chart[start] = [(ip, p, rhs) for ip, p, rhs in chart[start]
		if current.isdisjoint(rhs)]
	for n, (ip, p, rhs) in zip(count(), chart[start])[::-1]:
		for a in rhs:
			if a in chart and a not in visited:
				filtercycles(chart, a, visited, current.union([start, a]))
			#if a not in chart:
			#	del chart[start][n]
			#	break
	if not len(chart[start]): del chart[start]
	#return not len(chart[start]):

cpdef list getviterbi(dict chart, ChartItem start, dict mem):
	""" recompute the proper viterbi probabilities in a top-down fashion,
		and sort chart entries according to these probabilities
		removes zero-probability edges (infinity with log-probabilities)
		also tracks items visited, for pruning purposes (keys of mem).

		FIXME: not working yet. it seems to be more efficient to do
		the viterbi thing during parsing -- the log n overhead of
		the priority queue is small
	"""
	cdef list probs, bestprops
	cdef double prob, bestprob
	cdef int n
	probs = []
	bestprob = 999999 #float('infinity')
	try: assert len(chart[start])
	except: print "empty", start
	# loop backwards because we want to remove items in-place without
	# invalidating remaining indices.
	for n, (ip, p, rhs) in zip(count(), chart[start])[::-1]:
		probs[:] = [p]
		for a in rhs:
			# only recurse for nonterminals (=nonzero ids)
			if a.label and a in chart:
				if a in mem: result = mem[a]
				else: result = getviterbi(chart, a, mem)
				if not isinstance(result, list):
					print "trouble", start, '->', a
				probs.extend(result)
		prob = fsum(probs)
		if prob < bestprob:
			bestprob = prob
			bestprobs = probs[:]
		# prune or update probability
		if isinf(prob): del chart[start][n]
		else: chart[start][n] = (prob, p, rhs)
	if len(chart[start]):
		chart[start].sort(key=itemgetter(0))
		assert fsum(bestprobs) == chart[start][0][0]
	else:
		bestprobs = [float('infinity')]
	mem[start] = bestprobs
	return bestprobs

cdef samplechart(dict chart, ChartItem start, dict tolabel):
	iscore, p, entry = choice(chart[start])
	if entry[0].label == 0: # == "Epsilon":
		return "(%s %d)" % (tolabel[start.label], entry[0].vec), p
	children = [samplechart(chart, a, tolabel) for a in entry]
	tree = "(%s %s)" % (tolabel[start.label],
							" ".join([a for a,b in children]))
	return tree, fsum([p] + [b for a,b in children])

removeids = re.compile("@[0-9]+")
def mostprobableparse(chart, start, tolabel, n=10, sample=False, both=False, shortest=False, secondarymodel=None):
	""" sum over n random/best derivations from chart,
		return a dictionary mapping parsetrees to probabilities """
	print "sample =", sample or both, "kbest =", (not sample) or both,
	if both:
		derivations = set(samplechart(<dict>chart, start, tolabel) for x in range(n*100))
		derivations.discard(None)
		derivations.update(lazykbest(<dict>chart, start, n, tolabel))
		#derivations.update(islice(enumchart(chart, start, tolabel, n), n))
	elif sample:
		#filtercycles(chart, start, set(), set())
		derivations = set(samplechart(<dict>chart, start, tolabel) for x in range(n))
		derivations.discard(None)
		#calculate real parse probabilities according to Goodman's claimed
		#method?
	else:
		#mem = {}
		#filtercycles(chart, start, set(), set())
		#getviterbi(<dict>chart, start, mem)
		#for a in set(chart.keys()) - set(mem.keys()): del chart[a]
		#print "pruned chart keys", len(chart), "/ values", sum(map(len, chart.values()))
		#for a in chart: chart[a].sort(key=itemgetter(0))
		#derivations = list(islice(enumchart(chart, start, tolabel, n), n))
		#fixme: set shouldn't be necessary
		derivations = set(lazykbest(<dict>chart, start, n, tolabel))
		#print len(derivations)
		#print "enumchart:", len(list(islice(enumchart(chart, start, tolabel), n)))
		#assert(len(list(islice(enumchart(chart, start), n))) == len(set((a.freeze(),b) for a,b in islice(enumchart(chart, start), n))))
	if shortest:
		derivations = [(a,b) for a, b in derivations if b == derivations[0][1]]
	#cdef dict parsetrees = <dict>defaultdict(float)
	cdef dict parsetrees = <dict>defaultdict(list)
	cdef double prob, maxprob
	cdef int m = 0
	#cdef str deriv, tree
	for deriv, prob in derivations:
		m += 1
		#parsetrees[removeids.sub("", deriv)] += exp(-prob)
		#restore linear precedence (disabled, seems to make no difference)
		#parsetree = Tree(removeids.sub("", deriv))
		#for a in list(parsetree.subtrees())[::-1]:
		#	a.sort(key=lambda x: x.leaves())
		#parsetrees[parsetree.pprint(margin=999)].append(-prob)
		if shortest:
			tree = Tree(removeids.sub("", deriv))
			sent = sorted(tree.leaves(), key=int)
			rules = induce_srcg([tree], [sent], arity_marks=False)
			prob = -fsum([secondarymodel[r] for r, w in rules
											if r[0][1] != 'Epsilon'])
		parsetrees[removeids.sub("", deriv)].append(-prob)
	# Adding probabilities in log space
	# http://blog.smola.org/post/987977550/log-probabilities-semirings-and-floating-point-numbers
	# https://facwiki.cs.byu.edu/nlp/index.php/Log_Domain_Computations
	for parsetree in parsetrees:
		maxprob = max(parsetrees[parsetree])
		#foo = sum(map(exp, parsetrees[parsetree]))
		parsetrees[parsetree] = exp(fsum([maxprob, log(fsum([exp(prob - maxprob)
										for prob in parsetrees[parsetree]]))]))
		#assert log(foo) == parsetrees[parsetree]
	print "(%d derivations, %d parsetrees)" % (m, len(parsetrees))
	return parsetrees

def binrepr(a, sent):
	return bin(a.vec)[2:].rjust(len(sent), "0")[::-1]

def pprint_chart(chart, sent, tolabel):
	print "chart:"
	for a in sorted(chart, key=lambda x: bitcount(x[1])):
		print "%s[%s] =>" % (tolabel[a.label], binrepr(a, sent))
		for edge in chart[a]:
			print "%g\t%g" % (exp(-edge.inside), exp(-edge.prob)),
			if edge.left.label:
				print "\t%s[%s]" % (tolabel[edge.left.label],
									binrepr(edge.left, sent)),
			else:
				print "\t", repr(sent[edge.left.vec]),
			if edge.right:
				print "\t%s[%s]" % (tolabel[edge.right.label],
									binrepr(edge.right, sent)),
			print
		print

def do(sent, grammar):
	print "sentence", sent
	chart, start = parse(sent.split(), grammar, start=grammar.toid['S'])
	pprint_chart(chart, sent.split(), grammar.tolabel)
	if start == NONE:
		print "no parse"
	else:
		print "10 best parse trees:"
		mpp = mostprobableparse(chart, start, grammar.tolabel)
		for a, p in reversed(sorted(mpp.items(), key=itemgetter(1))): print p,a
		print

def main():
	from rcgrules import newsplitgrammar
	grammar = newsplitgrammar([
		((('S','VP2','VMFIN'), ((0,1,0),)), 0),
		((('VP2','VP2','VAINF'),  ((0,),(0,1))), log(0.5)),
		((('VP2','PROAV','VVPP'), ((0,),(1,))), log(0.5)),
		((('VP2','VP2'), ((0,),(1,))), log(0.1)),
		((('PROAV', 'Epsilon'), ('Daruber', ())), 0.0),
		((('VAINF', 'Epsilon'), ('werden', ())), 0.0),
		((('VMFIN', 'Epsilon'), ('muss', ())), 0.0),
		((('VVPP', 'Epsilon'), ('nachgedacht', ())), 0.0)])

	do("Daruber muss nachgedacht werden", grammar)
	do("Daruber muss nachgedacht werden werden", grammar)
	do("Daruber muss nachgedacht werden werden werden", grammar)
	do("muss Daruber nachgedacht werden", grammar)	#no parse

if __name__ == '__main__': main()
