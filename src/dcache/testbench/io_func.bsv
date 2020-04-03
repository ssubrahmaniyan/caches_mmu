/* 
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package io_func;
 
  // this function is used to indicate the caches which are the non-cacheable regions within the
  // Soc.
  function Bool isIO(Bit#(`paddr) addr, Bool cacheable);
	  if(!cacheable)
		  return True;
	  else if(addr < 'h1000)
	    return True;
	  else
		  return False;
  endfunction

endpackage

