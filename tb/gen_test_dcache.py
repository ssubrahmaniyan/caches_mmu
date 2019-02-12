import os
import sys
import math
import random
# parameters:

tbfile=open('dcache_tb.bsv','r')

for lineno,line in enumerate(tbfile):
    if '`define' in line:
      if 'sets' in line:
        line=line.split()
        sets=int(line[2])
      if 'word_size' in line:
        line=line.split()
        word_size=int(line[2])
      if 'block_size' in line:
        line=line.split()
        block_size=int(line[2])
      if 'addr_width' in line:
        line=line.split()
        addr_width=int(line[2])
      if 'ways' in line:
        line=line.split()
        ways=int(line[2])
      if 'repl' in line:
          line=line.split()
          repl=line[2]

print('Generating test for Following Parameters: ')
print('Sets: '+str(sets))
print('Ways: '+str(ways))
print('Word_size: '+str(word_size))
print('Block_size: '+str(block_size))
print('Addr_width: '+str(addr_width))
print('Repl_Policy: '+str(repl))



# globals:
read='read'
write='write'
atomic='atomic'
endsim='endsim'
delay='delay'
nodelay='nodelay'
fence='fence'
nofence='nofence'
byte='byte'
hword='halfword'
word='word'
dword='dword'
signed='signed'
unsigned='unsigned'

maxaddr=4294967295

nibbles=int(math.ceil((addr_width+8+(word_size*8))/4))
test_file=open('test.mem','w')
gold_file=open('gold.mem','w')
miss='0\n'
hit='1\n'

global entrycount
entrycount=0

def write_to_file(addr,readwrite, size, sign, delaycycle, fencecycle):


    data = random.randrange(4294967296)
    if readwrite == 'read':
      rw=int(format(1,'#04b'),2)
    elif readwrite == 'write':
      rw=int(format(2,'#04b'),2)
    elif readwrite == 'atomic':
      rw=int(format(3,'#04b'),2)
    else:
      rw=int(format(0,'#04b'),2)

    if delaycycle == 'delay':
      d=0b1
    else:
      d=0b0

    if fencecycle == 'fence':
      f=0b1
    else:
      f=0b0

    if size== 'byte':
      s=int(format(0,'#04b'),2)
    elif size == 'halfword':
      s=int(format(1,'#04b'),2)
    elif size == 'word':
      s=int(format(2,'#04b'),2)
    elif size == 'dword':
      s=int(format(3,'#04b'),2)

    if sign == 'signed':
      sg=0b0
    elif sign == 'unsigned':
      sg=0b1
    # test format:
    # read/write : size: sign: delay/nodelay : Fence/noFence : Null : Addr
    upperbits=((rw<<6) | (sg<<5) | (s<<3) | (d<<2) | (f<<1) | f)
    s = str(hex( (upperbits<<addr_width) | addr | (data<<(addr_width+8))))
    test_file.write(s[2:].zfill(nibbles)+'\n')
    return 0



# this test will generate consecutive requests on the same line.
# each request will be a miss in the cache and probably a hit a in the Line
# buffer if present.
def test1():
    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    address=4096
    for i in range(block_size):
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

# This test will generate consecutive requests to different sets of the cache
# All should be a cold miss
def test2():
    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    address=4096
    
    for i in range(sets):
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      gold_file.write(miss)
      address=address+(word_size*block_size)
      entrycount=entrycount+1

    for i in range(40):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1

    address=4096
    for i in range(sets):
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      gold_file.write(hit)
      address=address+(word_size*block_size)
      entrycount=entrycount+1

    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

# This test will first fill a line and then generate a request on the same line
# after significant delay.
def test3():
    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1

    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

# This test will first fill a line and after significant delay fill up the
# next line and immediately generate a request for the first line that was
# filled.
def test4():
    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    address=address+(word_size*block_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
   
# This test will first fill a line. After significant delay it will then
# generate a request for all words within the same line. They should all be hits
# in the cache.
def test5():
    global entrycount
    
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    for i in range(block_size):
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      gold_file.write(hit)
      entrycount=entrycount+1
      address=address+word_size
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

# this test will generate a cache request and then a IO request
def test6():
    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=32
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

def test7():
    global entrycount
  
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    address=address+(word_size*block_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4100
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

# the following test will check for a possibility where a LB miss and Cache miss will
# occur for different addresses (cache array output is registered)
# Req to a line which will be CM, then req a word in the same line after a delay.
# Then req a line in diff set which would be miss.
def test8():
    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    for i in range(5):
        write_to_file(address,read,word,unsigned,delay,nofence)
        gold_file.write(miss)
        entrycount=entrycount+1
  
    address=4096+4
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1

    address=address+(word_size*block_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

# this test creates a thrashing scenario on the same set. Total requests =
# 2*ways
def test9():
    global entrycount
    
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    for i in range(ways+ways+ways+1):
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1
      address=address+(word_size*block_size*sets)
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1



# first fill a set completely. Then access the lines in that set from line 0 to 3.
# Then generate 2 misses to that set.
# This test to assess how PLRU is affected by hits before generating those misses.
# RR wont have an effect because of the hits.
# gold file w.r.t PLRU
def test10():
    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    for i in range(ways):
        write_to_file(address,read,word,unsigned,nodelay,nofence)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*block_size*sets)

    address=4096+(word_size*block_size) # a miss to fully fill the set
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096 # accessing lines from 0 to 3
    address=address+(word_size*block_size*sets*(ways-1)) # this would set next_repl to be line 0
    for i in range(ways): 
        write_to_file(address,read,word,unsigned,nodelay,nofence)
        gold_file.write(hit)
        entrycount=entrycount+1
        address=address-(word_size*block_size*sets)
        
    address=4096
    address=address+(word_size*block_size*sets*(ways)) # miss to the set, would replace line 0 and set next_repl to line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=address+(word_size*block_size*sets) # another miss to the set, would replace line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*block_size*2) # miss to a different set to write back lb contents, line 0 and 2 get replaced
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4096+(word_size*block_size*sets) # request to old line 2, should be a miss
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    if repl=="PLRU" :
        gold_file.write(hit)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1

    address=4096+(word_size*block_size*sets*(ways-1)) # request to old line 0, should be a miss 
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    if repl=="PLRU" :
        gold_file.write(miss)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1



## test consists of combination of misses and hits and then requesting certain lines.
# gives better understanding of PLRU policy in a sense as how hits between misses changes next replacement line.
# gold file w.r.t PLRU
def test11():
    global entrycount
   
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    for i in range(ways+1): #  1st miss after filling the set would replace line 3, next_repl would be set to line 0 
        write_to_file(address,read,word,unsigned,nodelay,nofence)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*block_size*sets)

    address=4096
    address=address+(word_size*block_size) # miss (to a diff set) to actually replace line 3 (needed due to lazy write back)
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*block_size*sets*2) # Req for line 1(2000) is hit, would set next_repl as line2
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1

    address=4096+(word_size*block_size*sets*5) # miss to that set would replace line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*block_size*2) # miss(to diff set) for lb to update cache and actually replace line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*block_size*sets) # request to line 2 (addr-1800) would be a miss
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1

    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1


# fill a set completely, generate a miss (line 3 would be taken) but prevent lb writing back to cache.
# generate requests to line 3 which would be hits, they would change next_repl lines.
# genertate miss (to a diff set), it would replace line 3 as lb alread,word,unsignedy had next_repl as line 3,
# even though there were hits for line 3.
# gold file w.r.t PLRU

def test12():
    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    for i in range(ways+1): # filling set completely + generating a miss
        write_to_file(address,read,word,unsigned,nodelay,nofence)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*block_size*sets)

    address=4096 # 2 hits to line 3
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1
    if repl=="PLRU":
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      gold_file.write(hit)
      entrycount=entrycount+1
    elif repl=="RROBIN":
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      gold_file.write(hit)
      entrycount=entrycount+1

   
    address=4096+(word_size*block_size) # miss to make lb write back to cache
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096 # request to old line 3
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    if repl=="PLRU" :
        gold_file.write(hit)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

# fill the set completely, req line 3(a hit), generate 2 misses, request line 3 again
# this line 3 request should be a hit for PLRU and miss for RROBIN
# gold file w.r.t RROBIN

def test13():
    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    for i in range(ways):
        write_to_file(address,read,word,unsigned,nodelay,nofence)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*block_size*sets)
   
    
    address=4096+(word_size*block_size) # miss lb to write back to cache 
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence) #request to line 3
    gold_file.write(hit)
    entrycount=entrycount+1

    address=4096+(word_size*block_size*sets*4) # 1st miss
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*block_size*sets*5) # 2nd miss
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence) # request to old line 3
    if repl=="PLRU" :
        gold_file.write(hit)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1


#Filling 2 lines in different sets, then requesting the same lines in same order
#1st req would be a hit in cache and other in lb.
#This checks for a possibility of hits coming from different addresses in same cycle.
#Test to ensure correct implementation of RAMREG.
def test14a():
    global entrycount
    
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=address+(word_size*block_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
   
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    address=4096 # 1st req
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1

    address=address+(word_size*block_size) # 2nd req
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
   

#Same idea as test 14a, but after filling the lines, the requests are made in reverse order.
#1st req would be hit in lb, 2nd one in cache.
#For 1st req, once it is a hit in lb, cache check (supposed to happen in cycle after lb check) wont happen at all,
#as the req would have been dequed alread,word,unsignedy.
def test14b():
    global entrycount
    
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=address+(word_size*block_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
   
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    write_to_file(address,read,word,unsigned,nodelay,nofence) #1st req
    gold_file.write(hit)
    entrycount=entrycount+1

    address=4096 # 2nd req
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(hit)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
 


# Test to gaurantee consecutive IO requests are all misses and they dont change replacement state.
# Fill up a set, then make 2 IO requests which index to the same set. Both should be misses.
# make req to a line which maps to the above set. It would be a miss and would take way 3 as replacement,
# even though there were 2 IO misses to that set.

def test15():
    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4128
    for i in range(ways): # filling set completely
        write_to_file(address,read,word,unsigned,nodelay,nofence)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*block_size*sets)

    address=32 # 2 IO requests indexing to same set
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4128+(word_size*block_size*sets*4) # req to a new line mapping to that set
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

################### DCACHE Tests ##############################################

# test will first generate a store miss to all words of a line. These are
# expected to be updated in the linebuffer itself. The same line is then read to
# verify if the store as succeeded.
def test16():
    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    for i in range(block_size):
      write_to_file(address,write,word,unsigned,nodelay,nofence)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    for i in range(block_size):
      write_to_file(address,read,word,unsigned,nodelay,nofence)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size

    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0


# The test will generate a store miss on the least byte of the line and then a
# store on highest byte of the line. This is followed by reading least and
# highest 4-byte word from the same line. Except for the first store all other
# accesses should be a hit.
def test17():
    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,write,byte,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*block_size)-1
    write_to_file(address,write,byte,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(miss)

    address=4096
    write_to_file(address,read,hword,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=address+(word_size*block_size)-4
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)

    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0


# This test if for reading signed and unsigned bytes, halfwords, etc from the
# the cache.
def test18():

    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    
    address=4128
    write_to_file(address,read,byte,signed,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(miss)

    write_to_file(address,read,byte,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=address+2
    write_to_file(address,read,byte,signed,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(address,read,byte,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(address,read,hword,signed,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(address,read,hword,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=address+2
    write_to_file(address,read,word,signed,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
   
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

def test19():


    global entrycount

    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4096
    for i in range(block_size):
      write_to_file(address,write,word,unsigned,nodelay,nofence)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    address=address+(block_size*word_size)
    for i in range(block_size):
      write_to_file(address,write,word,unsigned,nodelay,nofence)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    address=address+(block_size*word_size)
    write_to_file(address,write,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(miss)

    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence)
      gold_file.write(miss)
      entrycount=entrycount+1
  

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=4096
    write_to_file(address,write,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=address+(block_size*word_size)+(block_size*word_size)
    write_to_file(address,write,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=address+(block_size*word_size)+(block_size*word_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=4128
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(miss)

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

# This test will thrash a single set with requests which is equal to the number
# of the fill-buffer entries and then generate a new request to the first line.
# This continuous thrashing will cause the fill-buffer to become full and threby
# cause a fill of the first line into the cache. This should also trigger a
# replay of the request
def test20():
    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    address=4096
    for i in range(8):
        write_to_file(address,read,word,unsigned,nodelay,nofence)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*block_size*sets)

#    for i in range(40):
#      write_to_file(address,read,word,unsigned,delay,nofence)
#      gold_file.write(miss)
#      entrycount=entrycount+1

    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0


def test21():

    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(miss)
    
    address=4096
    write_to_file(address,write,byte,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=4097
    write_to_file(address,read,byte,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=4096
    write_to_file(address,write,hword,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

test1()
test2()
test3()
test4()
test5()
#test6() 
test7()
test8()
test9()
test10()
test11()
test12()
test13()
test14a()
test14b()
#test15()
#test16()
#test17()
#test18()
#test19()
#test20()
#test21()
write_to_file(0,endsim,byte,signed,nodelay,nofence)
gold_file.write(miss)
entrycount=entrycount+1
print("Total Entries in Test: "+str(entrycount))
while entrycount<1024:
    gold_file.write(miss)
    write_to_file(0,endsim,byte,signed,nodelay,nofence)
    entrycount=entrycount+1

test_file.close()
gold_file.close()

