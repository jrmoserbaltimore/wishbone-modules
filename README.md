Wishbone Modules
----------------

# WishboneBRAM

A BRAM module accessed via Wishbone, for use when multiple subsystems might
share access to BRAM and so a bus arbiter is required.

* Granularity is always 8 bits.
* Address bus uses partial addressing:  the LSBs are ignored based on the data
  bus width.  For example:  a 64-bit data bus width is addressed by 64-bit
  pages, and an initiator looking to read at byte-granularity must use `SEL_O.`
* Full address is decoded as `{{Address},{SEL_I}}`, i.e. `SEL_I` represents
  the LSBs.
* If `Parity = 1`, `TGD[i]` contains the parity bit for byte `i`.
* The caller must send and interpret parity bits; the module does not care.
* The module never stalls and always generates `ACK_O` after `CYC_I & STB_I`.
* The module _never initializes BRAM_, and parity bits may be incorrect after
  power up or `RST_I`.  The caller should initialize BRAM or not read before
  first write if using parity.

An intermediate module can apply an error correcting code and may treat the
parity bit as simple storage, e.g. it may store 64-bit chunks and use the 8
parity bits for ECC.

# WishboneCrossbar

Paramaterized Wishbone crossbar in SystemVerilog.

# WishboneSkidBuffer

A skid buffer for pipelined mode
