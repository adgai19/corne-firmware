_default:
  @just --list

flash:
  cp /mnt/data/Downloads/firmware.zip .
  rm *.uf2
  unzip firmware.zip
  cp corny_left\ rgbled_adapter-seeeduino_xiao_ble-zmk.uf2 /run/media/adgai/XIAO-SENSE


