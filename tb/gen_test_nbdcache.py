import os
import sys
import math
import random
# parameters:

paramsfile=open('parameters.txt','r')

for lineno,line in enumerate(paramsfile):
    if '`define' in line:
      if 'Setsize' in line:
        line=line.split()
        sets=int(line[2])
      if 'Wordsize' in line:
        line=line.split()
        word_size=int(line[2])
      if 'Linesize' in line:
        line=line.split()
        line_size=int(line[2])
      if 'Paddr' in line:
        line=line.split()
        addr_width=int(line[2])
      if 'Buswidth' in line:
        line=line.split()
        bus_width=int(line[2])
      if 'Ways' in line:
        line=line.split()
        ways=int(line[2])
      if 'Mshrsize' in line:
        line=line.split()
        mshrsize=int(line[2])
      if 'Repl' in line:
        line=line.split()
        repl=line[2]
      if 'Rob_index' in line:
        line=line.split()
        rob_id_size=int(line[2])

repl='RANDOM'

print('Generating test for Following Parameters: ')
print('Sets: '+str(sets))
print('Ways: '+str(ways))
print('Word_size: '+str(word_size))
print('line_size: '+str(line_size))
print('Addr_width: '+str(addr_width))
print('Bus_width: '+str(bus_width))
print('Repl_Policy: '+str(repl))
print('Rob_index size: '+str(rob_id_size))



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

#nibbles=int(math.ceil((addr_width+8+bus_width)/4))
nibbles=0
test_file=open('test.mem','w')
gold_file=open('gold.mem','w')
miss='0\n'
hit='1\n'

global entrycount
entrycount=0

def write_to_file(addr,readwrite, size, sign, delaycycle, fencecycle, rob_id):


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
    s = str(hex( addr | (upperbits<<addr_width) | (rob_id<<(addr_width+8)) | (data<<(addr_width+8+rob_id_size))))
    test_file.write(s[2:].zfill(nibbles)+'\n')
    return 0

rob_index=0
# This is a dummy test to verify if the nb_dcache verification framework works
def test0():
    global entrycount
    address=4096
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

# Secondary miss to buswidth word
def test01():
    global entrycount
    address=4096
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    address=address+(bus_width//8)
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

# Primary miss to consecutive line addresses
def test02():
    global entrycount
    address=4096
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    address=address+(word_size*line_size)
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0


def test03():
    global entrycount
    address=4096
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
    address1=address
    address=address+(word_size*line_size)
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    address=address1
    address=address+(bus_width//8)
    write_to_file(address,read,dword,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

# Store to a line, followed by a load
def test04():
    global entrycount
    address=4096+4
    write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

# this test will generate consecutive requests on the same line.
# each request will be a miss in the cache and probably a hit a in the Line
# buffer if present.
def test1():
    global entrycount
    address=4096
    for i in range(line_size):
      write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    return 0

# This test will generate consecutive requests to different sets of the cache
# All should be a cold miss
def test2():
    global entrycount
    address=4096
    for i in range(2*sets):
      write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
      gold_file.write(hit)
      address=address+(word_size*line_size)
      entrycount=entrycount+1

# This test will first fill a line and then generate a request on the same line
# after significant delay.
def test3():
    global entrycount
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1

    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1
    
# This test will first fill a line and after significant delay fill up the
# next line and immediately generate a request for the first line that was
# filled.
def test4():
    global entrycount

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1
    
# This test will first fill a line. After significant delay it will then
# generate a request for all words within the same line. They should all be hits
# in the cache.
def test5():
    global entrycount
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    for i in range(line_size):
      write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
      gold_file.write(hit)
      entrycount=entrycount+1
      address=address+word_size
    
# this test will generate a cache request and then a IO request
def test6():
    global entrycount
    write_to_file(0,read,word,unsigned,nodelay,fence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=32
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1
    
    write_to_file(maxaddr,atomic,dword,unsigned,delay,fence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

def test7():
    global entrycount
  
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4100
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1

# the following test will check for a possibility where a LB miss and Cache miss will
# occur for different addresses (cache array output is registered)
# Req to a line which will be CM, then req a word in the same line after a delay.
# Then req a line in diff set which would be miss.
def test8():
    global entrycount

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    for i in range(5):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        gold_file.write(miss)
        entrycount=entrycount+1
  
    address=4096+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
# this test creates a thrashing scenario on the same set. Total requests =
# 2*ways
def test9():
    global entrycount
    
    address=4096
    for i in range(ways+ways+ways+1):
      write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
      address=address+(word_size*line_size*sets)
    


# first fill a set completely. Then access the lines in that set from line 0 to 3.
# Then generate 2 misses to that set.
# This test to assess how PLRU is affected by hits before generating those misses.
# RR wont have an effect because of the hits.
# gold file w.r.t PLRU
def test10():
    global entrycount

    address=4096
    for i in range(ways):
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*line_size*sets)

    address=4096+(word_size*line_size) # a miss to fully fill the set
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096 # accessing lines from 0 to 3
    address=address+(word_size*line_size*sets*(ways-1)) # this would set next_repl to be line 0
    for i in range(ways): 
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        gold_file.write(hit)
        entrycount=entrycount+1
        address=address-(word_size*line_size*sets)
        
    address=4096
    address=address+(word_size*line_size*sets*(ways)) # miss to the set, would replace line 0 and set next_repl to line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=address+(word_size*line_size*sets) # another miss to the set, would replace line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*line_size*2) # miss to a different set to write back lb contents, line 0 and 2 get replaced
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4096+(word_size*line_size*sets) # request to old line 2, should be a miss
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    if repl=="PLRU" :
        gold_file.write(hit)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1

    address=4096+(word_size*line_size*sets*(ways-1)) # request to old line 0, should be a miss 
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    if repl=="PLRU" :
        gold_file.write(miss)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1
    


## test consists of combination of misses and hits and then requesting certain lines.
# gives better understanding of PLRU policy in a sense as how hits between misses changes next replacement line.
# gold file w.r.t PLRU
def test11():
    global entrycount
   
    address=4096
    for i in range(ways+1): #  1st miss after filling the set would replace line 3, next_repl would be set to line 0 
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*line_size*sets)

    address=4096
    address=address+(word_size*line_size) # miss (to a diff set) to actually replace line 3 (needed due to lazy write back)
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*line_size*sets*2) # Req for line 1(2000) is hit, would set next_repl as line2
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1

    address=4096+(word_size*line_size*sets*5) # miss to that set would replace line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*line_size*2) # miss(to diff set) for lb to update cache and actually replace line 2
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*line_size*sets) # request to line 2 (addr-1800) would be a miss
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1


# fill a set completely, generate a miss (line 3 would be taken) but prevent lb writing back to cache.
# generate requests to line 3 which would be hits, they would change next_repl lines.
# genertate miss (to a diff set), it would replace line 3 as lb alread,word,unsignedy had next_repl as line 3,
# even though there were hits for line 3.
# gold file w.r.t PLRU

def test12():
    global entrycount

    address=4096
    for i in range(ways+1): # filling set completely + generating a miss
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*line_size*sets)

    address=4096 # 2 hits to line 3
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1
    if repl=="PLRU":
      write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
      gold_file.write(hit)
      entrycount=entrycount+1
    elif repl=="RROBIN":
      write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
      gold_file.write(hit)
      entrycount=entrycount+1

   
    address=4096+(word_size*line_size) # miss to make lb write back to cache
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096 # request to old line 3
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    if repl=="PLRU" :
        gold_file.write(hit)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1
    
# fill the set completely, req line 3(a hit), generate 2 misses, request line 3 again
# this line 3 request should be a hit for PLRU and miss for RROBIN
# gold file w.r.t RROBIN

def test13():
    global entrycount

    address=4096
    for i in range(ways):
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*line_size*sets)
   
    
    address=4096+(word_size*line_size) # miss lb to write back to cache 
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence, rob_index) #request to line 3
    gold_file.write(hit)
    entrycount=entrycount+1

    address=4096+(word_size*line_size*sets*4) # 1st miss
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096+(word_size*line_size*sets*5) # 2nd miss
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence, rob_index) # request to old line 3
    gold_file.write(miss)
    entrycount=entrycount+1
    if repl=="PLRU" :
        gold_file.write(hit)
        entrycount=entrycount+1
    if repl=="RROBIN" :
        gold_file.write(hit)
        entrycount=entrycount+1
    

#Filling 2 lines in different sets, then requesting the same lines in same order
#1st req would be a hit in cache and other in lb.
#This checks for a possibility of hits coming from different addresses in same cycle.
#Test to ensure correct implementation of RAMREG.
def test14a():
    global entrycount
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
   
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    address=4096 # 1st req
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1

    address=address+(word_size*line_size) # 2nd req
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1
    

#Same idea as test 14a, but after filling the lines, the requests are made in reverse order.
#1st req would be hit in lb, 2nd one in cache.
#For 1st req, once it is a hit in lb, cache check (supposed to happen in cycle after lb check) wont happen at all,
#as the req would have been dequed alread,word,unsignedy.
def test14b():
    global entrycount
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
   
    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
  
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #1st req
    gold_file.write(hit)
    entrycount=entrycount+1

    address=4096 # 2nd req
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(hit)
    entrycount=entrycount+1
 


# Test to gaurantee consecutive IO requests are all misses and they dont change replacement state.
# Fill up a set, then make 2 IO requests which index to the same set. Both should be misses.
# make req to a line which maps to the above set. It would be a miss and would take way 3 as replacement,
# even though there were 2 IO misses to that set.

def test15():
    global entrycount

    address=4128
    for i in range(ways): # filling set completely
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*line_size*sets)

    address=32 # 2 IO requests indexing to same set
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
    address=4128+(word_size*line_size*sets*4) # req to a new line mapping to that set
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    gold_file.write(miss)
    entrycount=entrycount+1
    
################### DCACHE Tests ##############################################

# test will first generate a store miss to all words of a line. These are
# expected to be updated in the linebuffer itself. The same line is then read to
# verify if the store as succeeded.
def test16():
    global entrycount

    address=4096
    for i in range(line_size):
      write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    address=4096
    for i in range(line_size):
      write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size

    return 0


# The test will generate a store miss on the least byte of the line and then a
# store on highest byte of the line. This is followed by reading least and
# highest 4-byte word from the same line. Except for the first store all other
# accesses should be a hit.
def test17():
    global entrycount

    address=4096
    write_to_file(address,write,byte,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*line_size)-1
    write_to_file(address,write,byte,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)

    address=4096
    write_to_file(address,read,hword,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=address+(word_size*line_size)-4
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)

    return 0


# This test if for reading signed and unsigned bytes, halfwords, etc from the
# the cache.
def test18():

    global entrycount

    address=4128
    write_to_file(address,read,byte,signed,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)

    write_to_file(address,read,byte,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=address+2
    write_to_file(address,read,byte,signed,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(address,read,byte,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(address,read,hword,signed,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    write_to_file(address,read,hword,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=address+2
    write_to_file(address,read,word,signed,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
   
    return 0

def test19():


    global entrycount

    address=4096
    for i in range(line_size):
      write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    address=address+(line_size*word_size)
    for i in range(line_size):
      write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
      entrycount=entrycount+1
      if i == 0:
        gold_file.write(miss)
      else:
        gold_file.write(hit)
      address=address+word_size
    
    address=address+(line_size*word_size)
    write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)

    for i in range(20):
      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
      gold_file.write(miss)
      entrycount=entrycount+1
  

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=4096
    write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=address+(line_size*word_size)+(line_size*word_size)
    write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=address+(line_size*word_size)+(line_size*word_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)

    address=4128
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    return 0

# This test will thrash a single set with requests which is equal to the number
# of the fill-buffer entries and then generate a new request to the first line.
# This continuous thrashing will cause the fill-buffer to become full and threby
# cause a fill of the first line into the cache. This should also trigger a
# replay of the request
def test20():
    global entrycount
    address=4096
    for i in range(8):
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        gold_file.write(miss)
        entrycount=entrycount+1
        address=address+(word_size*line_size*sets)

#    for i in range(40):
#      write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
#      gold_file.write(miss)
#      entrycount=entrycount+1

    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    return 0


def test21():

    global entrycount

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)
    
    address=4096
    write_to_file(address,write,byte,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=4097
    write_to_file(address,read,byte,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    address=4096
    write_to_file(address,write,hword,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(hit)
    
    return 0

def test22a():

    global entrycount

    address=5000
    for i in range(20):
        address= address+1;
        write_to_file(address,write,byte,unsigned,nodelay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)
    
    return 0

#evicting a line and then loading it again
def test22b():
    global entrycount
    address=4096
    rob_index=0
    cache_size=word_size*line_size*sets

    for i in range(ways+2):
        write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index)
        rob_index=rob_index+1
        entrycount=entrycount+1
        gold_file.write(miss)
        address=address+cache_size

    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)

    return 0

##mshr full and still cache hits go on
def test23():
    global entrycount
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)
    
    for i in range(17):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    for i in range(mshrsize+3):
        address=address+(word_size*line_size)
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    address=4096
    for i in range(16):
        address=address+4
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

##mshr and ff_second_stage full and still cache hits go on
def test24():
    global entrycount
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    
    for i in range(17):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    for i in range(mshrsize+2):
        address=address+(word_size*line_size)
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    address=4096
    for i in range(16):
        address=address+4
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)


##mshr,  ff_first_stage and ff_second_stage full
def test25():
    global entrycount
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
    entrycount=entrycount+1
    gold_file.write(miss)
    
    for i in range(17):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    for i in range(mshrsize+3):
        address=address+(word_size*line_size)
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    address=4096
    for i in range(16):
        address=address+4
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

#flush test. Response comes only for rob_index 3 and 4 (prf_index 0 and 2).
def test26():
    global entrycount
    address=4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,3)
    entrycount=entrycount+1
    gold_file.write(miss)
    
    address=address+(word_size*1)
    write_to_file(address,read,word,unsigned,nodelay,nofence,20)
    entrycount=entrycount+1
    gold_file.write(miss)
    
    address=address+(word_size*2)
    write_to_file(address,read,word,unsigned,nodelay,nofence,4)
    entrycount=entrycount+1
    gold_file.write(miss)
    
    address=address+(word_size*3)
    write_to_file(address,read,word,unsigned,nodelay,nofence,21)
    entrycount=entrycount+1
    gold_file.write(miss)

    for i in range(4):
        write_to_file(address,read,word,unsigned,delay,nofence,11)
        entrycount=entrycount+1

    write_to_file(address,read,word,signed,delay,nofence,10)
    entrycount=entrycount+1

#This testcase tests if ff_second_stage has one entry, and MSHRs are full, then no new core requests can be taken as this needs to be evaluated for flushing (which can be done only when dequeueing this FIFO). One possible optimization is to add a array of registers on top of the FIFO and then set the valid bits accordingly (the same way valid bits are being maintained for MSHRs).
#OLD # Expected output with read delay  8 is 0,1,7,8,9,a,2,b,6
#OLD # Expected output with read delay 10 is 0,1,7,8,9,a,b,2,6
#NEW # Expected output with read delay  8 is 0,7,8,9,1,a,b,2,6
#NEW # Expected output with read delay 10 is 0,7,8,9,a,1,b,2,6
def test27():
    global entrycount
    address=4096
    rob_index=0
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #0
    entrycount=entrycount+1
    gold_file.write(miss)
    
    for i in range(17):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,1) #1
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,2) #2
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,21) #3
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,20) #4
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,22) #5
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,3) #6
    entrycount=entrycount+1
    gold_file.write(miss)

    write_to_file(address,read,word,signed,delay,nofence,10) #flush request (since rob=10)
    entrycount=entrycount+1

    address=4096
    rob_index=4
    for i in range(5):
        address=address+4
        rob_index=rob_index+1;
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #7,8,9,a,b
        entrycount=entrycount+1
        gold_file.write(miss)

#When a flush is asserted and an entry in mshr_fifo is invalidated, and when that request is popped,
#it should be discarded. In the same cycle, if a request from Stage 2 is a hit in the fill buffer, the
#response is sent for that request.
#Expected output is 0,1,6,7,4,8,9,a,b
def test28():
    global entrycount
    address=4096
    rob_index=0
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #0
    entrycount=entrycount+1
    gold_file.write(miss)
    
    for i in range(17):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,1) #1
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,20) #2
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,21) #3
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,2) #4
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,22) #5
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,3) #6
    entrycount=entrycount+1
    gold_file.write(miss)

    write_to_file(address,read,word,signed,delay,nofence,10) 
    entrycount=entrycount+1

    address=4096
    rob_index=4
    for i in range(5):
        address=address+4
        rob_index=rob_index+1;
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #7,8,9,a,b
        entrycount=entrycount+1
        gold_file.write(miss)

#When MSHR FIFO is full, all the requests are to the same line, and then a flush happens in between.
#Also, a request from stage 2 accesses FB when the top entry of ff_mshr, which has been flushed is
#being dequeued.
#Expected output: 0,6,3,4,7,8,9,a,b
def test29():
    global entrycount
    address=4096
    rob_index=0
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #0
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+(word_size*line_size)
    write_to_file(address,read,word,unsigned,nodelay,nofence,20) #1
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,21) #2
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,1) #3
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,2) #4
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address+4
    write_to_file(address,read,word,unsigned,nodelay,nofence,22) #5
    entrycount=entrycount+1
    gold_file.write(miss)

    address=address-12
    write_to_file(address,read,word,unsigned,nodelay,nofence,3) #6
    entrycount=entrycount+1
    gold_file.write(miss)

    write_to_file(address,read,word,signed,delay,nofence,10)
    entrycount=entrycount+1


    address=4096
    rob_index=4
    for i in range(5):
        address=address+4
        rob_index=rob_index+1;
        write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #7,8,9,a,b
        entrycount=entrycount+1
        gold_file.write(miss)

def test30():
    global entrycount
    address=4096
    rob_index=0
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #0
    entrycount=entrycount+1
    gold_file.write(miss)

    #address=address+8
    rob_index=rob_index+1
    write_to_file(address,write,word,unsigned,nodelay,nofence,rob_index) #1
    entrycount=entrycount+1
    gold_file.write(miss)

    for i in range(50):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    rob_index=rob_index+1
    write_to_file(address,write,word,unsigned,nodelay,fence,rob_index) #2
    entrycount=entrycount+1
    gold_file.write(miss)

    rob_index=rob_index+1
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #3
    entrycount=entrycount+1
    gold_file.write(miss)

    for i in range(20):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    rob_index=rob_index+1
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #3
    entrycount=entrycount+1
    gold_file.write(miss)

#Atomic AMOOR.D
def test31():
    global entrycount
    address=4096
    rob_index=0
    write_to_file(address,write,dword,unsigned,nodelay,nofence,rob_index) #0
    entrycount=entrycount+1
    gold_file.write(miss)

    rob_index=rob_index+1
    address= address+8
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #3
    entrycount=entrycount+1
    gold_file.write(hit)

#Load response missing issue. Nitya 05062020.
def test32():
    global entrycount
    address=4096
    rob_index=0
    for i in range(4):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)
    write_to_file(address,write,dword,unsigned,nodelay,nofence,rob_index) #0, 470, 1418
    entrycount=entrycount+1
    gold_file.write(miss)

    rob_index=rob_index+1
    address= 4100
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #1, 474, 13, 1458
    entrycount=entrycount+1
    gold_file.write(hit)

    for i in range(4):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    rob_index=rob_index+1
    address= 4108
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #2, 488, 1468
    entrycount=entrycount+1
    gold_file.write(hit)

    rob_index=rob_index+1
    address= 4104
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #3, 48c, 1478
    entrycount=entrycount+1
    gold_file.write(hit)

    for i in range(2):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    rob_index=rob_index+1
    address= 4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #4, 490, 1488
    entrycount=entrycount+1
    gold_file.write(hit)

    rob_index=rob_index+1
    address= 4100
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #5, 4a0
    entrycount=entrycount+1
    gold_file.write(hit)

    for i in range(2):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    rob_index=rob_index+1
    address= 4104
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #6, 04ac
    entrycount=entrycount+1
    gold_file.write(hit)
    gold_file.write(hit)

    for i in range(2):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    rob_index=rob_index+1
    address= 4108
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #7, 4b8
    entrycount=entrycount+1
    gold_file.write(hit)

    for i in range(18):
        write_to_file(address,read,word,unsigned,delay,nofence,rob_index)
        entrycount=entrycount+1
        gold_file.write(miss)

    rob_index=rob_index+1
    address= 4096
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #8, 504
    entrycount=entrycount+1
    gold_file.write(hit)

    rob_index=rob_index+1
    address= 4100
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #9
    entrycount=entrycount+1
    gold_file.write(hit)

    rob_index=rob_index+1
    address= 4104
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #10
    entrycount=entrycount+1
    gold_file.write(hit)

    rob_index=rob_index+1
    address= 4104
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #11
    entrycount=entrycount+1
    gold_file.write(hit)

    rob_index=rob_index+1
    address= 4108
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #12
    entrycount=entrycount+1
    gold_file.write(hit)

    rob_index=rob_index+1
    address= 4108
    write_to_file(address,read,word,unsigned,nodelay,nofence,rob_index) #13
    entrycount=entrycount+1
    gold_file.write(hit)

#All delays are indicated for read delay 10
#test0() #1548
#test02() #1698         #1610
#test03() #1788         #1700
#test04() #1558         #1470
#test1() #1658          #2880
#test2() #39798         #39710
#test3() #1668          #1580
#test4() #1788          #1700
#test5() #1858          #1770
##test6() 
#test7() #1788          #1700
#test8() #1698          #1610
#test9() #3348          #3260
#test10() #2748         #2660
#test11() #2758         #2670
#test12() #2458         #2370
#test13() #2608         #2520
#test14a() #1718        #1630
#test14b() #1718        #1630
#test15() #2298         #2210
#test16() #1868         #1780
#test17() #1598         #1510
#test18() #1618         #1530
#test19() #2308         #2220
#test20() #2608         #2520
#test21() #1588         #1500
#test22a() #1988        #1900
#test22b() #1608        #1520 
#test23() #2808         #2720
#test24() #2658         #2570
#test25() #2808         #2720
#test26() #no_end 1548  #1460
#test27() #no_end 2328  #2140/2240 for read delay 8/10
#test28() #no_end 1868  #1760
#test29() #no_end 1808  #1700
#test30()               #3460
#test31()               #1470
#test32()               #2010

write_to_file(0,endsim,byte,signed,nodelay,nofence,rob_index)
gold_file.write(miss)
entrycount=entrycount+1

print("Total Entries in Test: "+str(entrycount))
while entrycount<2048:
    gold_file.write(miss)
    write_to_file(0,endsim,byte,signed,nodelay,nofence,rob_index)
    entrycount=entrycount+1

test_file.close()
gold_file.close()

