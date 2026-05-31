//
//  rdata_bit.h - Bit-twiddling utility functions
//


int rdata_machine_is_little_endian(void);

uint16_t rdata_byteswap2(uint16_t num);
uint32_t rdata_byteswap4(uint32_t num);
uint64_t rdata_byteswap8(uint64_t num);

float rdata_byteswap_float(float num);
double rdata_byteswap_double(double num);
