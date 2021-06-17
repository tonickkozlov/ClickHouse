python
import sys
sys.path.insert(0, '/usr/local/share/gdb-printers-libcxx')
from printers import register_libcxx_printer_loader
register_libcxx_printer_loader()
end
