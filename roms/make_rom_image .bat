

# Create the 112K ROM image
#
# This contains 7x 16K ROMS images for the electron



cat mmfs_swram.rom             > rom_image.bin
cat os100.rom                  >> rom_image.bin
cat Basic2.rom                 >> rom_image.bin
cat pres_ap2_v1_23.rom         >> rom_image.bin
cat blank.rom                  >> rom_image.bin
cat blank.rom                  >> rom_image.bin
cat M7_191.rom                 >> rom_image.bin


srec.exe rom_image.bin -binary -output ELK.mif -mif

