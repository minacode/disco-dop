# probabilistic CKY parser for Simple Range Concatenation Grammars
# (equivalent to Linear Context-Free Rewriting Systems)
from rcgrules import fs, enumchart
from nltk import FreqDist
from heapdict import heapdict
from math import log, e, floor
from random import choice
from itertools import chain, islice
from pprint import pprint
from collections import defaultdict
from operator import or_
import re
#try:
#	import pyximport
#	pyximport.install()
#except: pass
#from bit import *
#try:
#	import psyco
#	psyco.full()
#except: pass
myintern = {}
def parse(sent, grammar, start="S", viterbi=False, n=1):
	""" parse sentence, a list of tokens, using grammar, a dictionary
	mapping rules to probabilities. """
	unary, binary = defaultdict(list), defaultdict(list)
	# negate the log probabilities because the heap is a min-heap
	for r,w in grammar:
		if len(r[0]) == 2: unary[r[0][1]].append((r, -w))
		elif len(r[0]) == 3: binary[(r[0][1], r[0][2])].append((r, -w))
	goal = freeze([start, (2**len(sent) - 1,)])
	m = maxA = 0
	A, C = heapdict(), {} #defaultdict(list)
	#A, C, Cx = {}, defaultdict(list), defaultdict(list)
	#preallocation: (seems to be only a waste of space/time)
	#for a in range(len(sent)**6/(len(sent)*500)): C[("S",a)]=(("S%d"%a,"NP%d"%a,"VP%d"%a), (a,a+1,a+2)); Cx[("S",a)] = 0.1
	#for a in range(len(sent)**6/(len(sent)*1000)): A[(("S%d"%a,"NP%d"%a,"VP%d"%a), (a,a+1,a+2))]=0.1
	#for a in A.keys(): del A[a] #A.clear()
	#C.clear(); Cx.clear()
	#from guppy import hpy; h = hpy(); hn = 0
	#h.heap().stat.dump("/tmp/hstat%d" % hn); hn+=1
	for i,w in enumerate(sent):
		recognized = False
		for rule, z in unary["Epsilon"]:
			if w in rule[1][0][0]:
				I = freeze(((rule[0][0], "Epsilon"), ((2**i,), (i,))))	
				Ih = zip(*I)[0]
				A[Ih] = ((z, z), I)
				recognized = True
		if not recognized: print "not covered:", w
	while A:
		Ih, (x, I) = A.popitem()
		#when heapdict is not available:
		#Ih, (x, I) = min(A.items(), key=lambda x:x[1]); del A[Ih]
		C[Ih] = I, x
		if Ih == goal:
			m += 1	#problem: this is not viterbi n-best.
			if viterbi and n==m: break
		else:
			for I1, y in deduced_from(Ih, x, C, unary, binary):
				I1h = zip(*I1)[0]
				if I1h not in C and I1h not in A:
					A[I1h] = (y, I1)
				elif I1h in A:
					if y > A[I1h][0]: A[I1h] = (y, I1)
				#else: raise #?
		maxA = max(maxA, len(A))
		#if maxA == 1536:
		#	pass #h.heap().stat.dump("/tmp/hstat%d" % hn); hn+=1
		#	#print h.iso(A,C,Cx).referents | h.iso(A, C, Cx)
	print "max agenda size", maxA, "/ chart items", len(C)
	#h.pb(*("/tmp/hstat%d" % a for a in range(hn)))
	for a in C: C[a] = [(zip(*b)[1:],-p) for b,(foo,p) in [C[a]]]
	return (C, goal) if goal in C else ({}, ())

def deduced_from(Ih, (x, foo), C, unary, binary):
	I, Ir = Ih
	result = []
	for rule, z in unary[I]:
		for a,b in zip(rule[1][1], Ir): a.append(b)
		left = concat(rule[1][0])
		if left: result.append(((rule[0], interntuple(left, Ir)), (x+z,z)))
	foldorIr = foldor(Ir)
	for (I1, I1r), (bar, (y, zed)) in C.items():
		#detect overlap in ranges
		if foldorIr & foldor(I1r): continue
		for rule, z in binary[(I, I1)]:
			for a,b in zip(rule[1][1], Ir): a.append(b)
			for a,b in zip(rule[1][2], I1r): a.append(b)
			left = concat(rule[1][0])
			if left: 
				result.append(((rule[0], (left, Ir, I1r)), (x+y+z,z)))
		for rule, z in binary[(I1, I)]:
			for a,b in zip(rule[1][1], I1r): a.append(b)
			for a,b in zip(rule[1][2], Ir): a.append(b)
			right = concat(rule[1][0])
			if right: 
				result.append(((rule[0], (right, I1r, Ir)), (x+y+z,z)))
	return result

def concat(node):
	# only concatenate when result will be contiguous
	contiguous = all(bitminmax(a[0],b[0]) for x in node for a,b in zip(x,x[1:]))
	#result = interntuple(*map(lambda s: reduce(lambda a,b: a|b.pop(), s, 0), node))
	result = tuple(map(lambda s: reduce(lambda a,b: a|b.pop(), s, 0), node))
	return result if contiguous else None

def foldor(s):
	# unrolled version of reduce(or, s) for speed
	if len(s) == 1: return s[0]
	if len(s) == 2: return s[0] | s[1]
	if len(s) == 3: return s[0] | s[1] | s[2]
	if len(s) == 4: return s[0] | s[1] | s[2] | s[3]
	return reduce(or_, s)

def interntuple(*a):
	#like intern but for tuples: return a canonical reference so that tuples are never stored twice. 
	#doesn't seem to make any difference, unfortunately.
	# note the *. wrong: interntuple([0,1]) correct interntuple(0,1)
    return myintern.setdefault(a, a)


# adapted from http://wiki.python.org/moin/BitManipulation
def bitminmax(a, b):
	"""test if the least and most significant bits of a and b are 
	consecutive. we shift a and b until they meet in the middle (return true)
	or collide (return false)"""
	b = (b & -b)
	while a and b:
		a >>= 1
		b >>= 1
	return b == 1
	
def bitmax1(int_type):
	return int(log(int_type, 2))

def freeze(l):
	if isinstance(l, list): return tuple(map(freeze, l))
	else: return l

def filterchart(chart, start):
	# remove all entries that do not contribute to a complete derivation
	def filter_subtree(start, chart, chart2):
		if isinstance(start, int) or chart2[start]: return True
		else: chart2[start] = [(x,p) for x,p in chart[start] if all(filter_subtree(a, chart, chart2) for a in x)]
		return chart2[start] != []
	chart2 = defaultdict(list)
	filter_subtree(start, chart, chart2)
	return chart2

def samplechart(chart, start):
	if chart[start]: entry, p = choice(chart[start])
	else: raise; return #shouldn't happen
	if len(entry) == 1 and entry[0][0] == "Epsilon":
		return "(%s %d)" % (start[0], entry[0][1][0]), p
	children = [samplechart(chart, a) for a in entry]
	tree = "(%s %s)" % (start[0], " ".join([a for a,b in children]))
	#tree = "(%s_%s %s)" % (start[0], "_".join(repr(a) for a in start[1:]), " ".join([a for a,b in children]))
	return tree, p+sum(b for a,b in children)
	
def mostprobableparse(chart, start, n=100, sample=False):
		""" sum over n random derivations from chart,
			return a FreqDist of parse trees, with .max() being the MPP"""
		print "sample =", sample,
		if sample:
			for a,b in chart.items():
				if not len(b): print "spurious chart entry", a
			derivations = set(samplechart(chart, start) for x in range(n))
			derivations.discard(None)
			#todo: calculate real parse probabilities
		else:
			#chart = filterchart(chart, start)
			for a in chart: chart[a].sort(key=lambda (x,y): y, reverse=True)
			derivations = islice(enumchart(chart, start), n)
		parsetrees = FreqDist()
		m = 0
		for n,(a,prob) in enumerate(derivations):
			parsetrees.inc(re.sub(r"@[0-9]+", "", a), e**prob)
			m+=1
		print "(%d derivations)" % m
		return parsetrees

def pprint_chart(chart, sent):
	print "chart:"
	def mybin(n):
		return ("0"*len(sent) + bin(n)[2:])[-len(sent)::][::-1]
	for a in sorted(chart, key=lambda x: bin(foldor(x[1:])).count("1")):
		print a[0], " ".join(mybin(d) for d in a[1:]), "=>"
		for b in chart[a]:
			try:
				for c in b[0]:
					print "\t", c[0], " ".join(mybin(d) for d in c[1:]),
				print
			except:	print repr(sent[b[0][0]]), b[1]
		print

def do(sent):
	print "sentence", sent
	chart, start = parse(sent.split(), grammar)
	pprint_chart(chart, sent.split())
	if chart:
		for a, p in mostprobableparse(chart, start, n=1000).items():
			print p, a
	else: print "no parse"
	print

if __name__ == '__main__':
	grammar =  [
		(fs("[['S',[?X,?Y,?Z]], ['VP2',?X,?Z], ['VMFIN',?Y]]"),  0),
		(fs("[['VP2',[?X],[?Y,?Z]],['VP2',?X,?Y], ['VAINF',?Z]]"),  log(0.5)),
		(fs("[['VP2',[?X],[?Y]], ['PROAV',?X], ['VVPP',?Y]]"),  log(0.5)),
		(fs("[['PROAV',['Daruber']], [Epsilon]]"),  0),
		(fs("[['VVPP',['nachgedacht']], [Epsilon]]"),  0),
		(fs("[['VMFIN',['muss']], [Epsilon]]"),  0),
		(fs("[['VAINF',['werden']], [Epsilon]]"), 0)
		]

	# a DOP reduction according to Goodman (1996)
	grammar =  [
		(fs("[['S',[?X,?Y,?Z]], ['VP2@3',?X,?Z], ['VMFIN@2',?Y]]"),  log(10/22.)),
		(fs("[['S',[?X,?Y,?Z]], ['VP2@3',?X,?Z], ['VMFIN',?Y]]"),  log(10/22.)),
		(fs("[['S',[?X,?Y,?Z]], ['VP2',?X,?Z], ['VMFIN@2',?Y]]"),  log(1/22.)),
		(fs("[['S',[?X,?Y,?Z]], ['VP2',?X,?Z], ['VMFIN',?Y]]"),  log(1/22.)),
		(fs("[['VP2',[?X],[?Y,?Z]], ['VP2@4',?X,?Y], ['VAINF@7',?Z]]"),  log(4/14.)),
		(fs("[['VP2',[?X],[?Y,?Z]], ['VP2@4',?X,?Y], ['VAINF',?Z]]"),  log(4/14.)),
		(fs("[['VP2',[?X],[?Y,?Z]], ['VP2',?X,?Y], ['VAINF@7',?Z]]"),  log(1/14.)),
		(fs("[['VP2',[?X],[?Y,?Z]], ['VP2',?X,?Y], ['VAINF',?Z]]"),  log(1/14.)),
		(fs("[['VP2@3',[?X],[?Y,?Z]], ['VP2@4',?X,?Y], ['VAINF@7',?Z]]"),  log(4/10.)),
		(fs("[['VP2@3',[?X],[?Y,?Z]], ['VP2@4',?X,?Y], ['VAINF',?Z]]"),  log(4/10.)),
		(fs("[['VP2@3',[?X],[?Y,?Z]], ['VP2',?X,?Y], ['VAINF@7',?Z]]"),  log(1/10.)),
		(fs("[['VP2@3',[?X],[?Y,?Z]], ['VP2',?X,?Y], ['VAINF',?Z]]"),  log(1/10.)),
		(fs("[['VP2',[?X],[?Y]], ['PROAV@5',?X], ['VVPP@6',?Y]]"),  log(1/14.)),
		(fs("[['VP2',[?X],[?Y]], ['PROAV@5',?X], ['VVPP',?Y]]"),  log(1/14.)),
		(fs("[['VP2',[?X],[?Y]], ['PROAV',?X], ['VVPP@6',?Y]]"),  log(1/14.)),
		(fs("[['VP2',[?X],[?Y]], ['PROAV',?X], ['VVPP',?Y]]"),  log(1/14.)),
		(fs("[['VP2@4',[?X],[?Y]], ['PROAV@5',?X], ['VVPP@6',?Y]]"),  log(1/4.)),
		(fs("[['VP2@4',[?X],[?Y]], ['PROAV@5',?X], ['VVPP',?Y]]"),  log(1/4.)),
		(fs("[['VP2@4',[?X],[?Y]], ['PROAV',?X], ['VVPP@6',?Y]]"),  log(1/4.)),
		(fs("[['VP2@4',[?X],[?Y]], ['PROAV',?X], ['VVPP',?Y]]"),  log(1/4.)),
		(fs("[['PROAV',['Daruber']], [Epsilon]]"),  0),
		(fs("[['PROAV@5',['Daruber']], [Epsilon]]"),  0),
		(fs("[['VVPP',['nachgedacht']], [Epsilon]]"),  0),
		(fs("[['VVPP@6',['nachgedacht']], [Epsilon]]"),  0),
		(fs("[['VMFIN',['muss']], [Epsilon]]"),  0),
		(fs("[['VMFIN@2',['muss']], [Epsilon]]"),  0),
		(fs("[['VAINF',['werden']], [Epsilon]]"),  0),
		(fs("[['VAINF@7',['werden']], [Epsilon]]"), 0)
		]

	#do("Daruber muss nachgedacht werden")
	do("Daruber muss nachgedacht werden werden")
	#do("Daruber muss nachgedacht werden werden werden")
	#do("muss Daruber nachgedacht werden")
