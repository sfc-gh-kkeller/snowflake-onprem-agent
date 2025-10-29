#!/usr/bin/env python3
"""Download DuckDB extensions during Docker build"""

import urllib.request
import gzip
import os

def main():
    # Create extension directory
    ext_dir = '/root/.duckdb/extensions/v1.4.1/linux_amd64'
    os.makedirs(ext_dir, exist_ok=True)
    
    extensions = [
        ('iceberg', 'https://extensions.duckdb.org/v1.4.1/linux_amd64/iceberg.duckdb_extension.gz'),
        ('httpfs', 'https://extensions.duckdb.org/v1.4.1/linux_amd64/httpfs.duckdb_extension.gz'),
        ('avro', 'https://extensions.duckdb.org/v1.4.1/linux_amd64/avro.duckdb_extension.gz'),
    ]
    
    for name, url in extensions:
        print(f'📥 Downloading {name} extension...')
        gz_path = f'/tmp/{name}.gz'
        ext_path = f'{ext_dir}/{name}.duckdb_extension'
        
        # Download
        urllib.request.urlretrieve(url, gz_path)
        
        # Decompress
        with gzip.open(gz_path, 'rb') as f_in:
            with open(ext_path, 'wb') as f_out:
                f_out.write(f_in.read())
        
        print(f'✅ {name} extension installed')
    
    print('✅ All extensions downloaded successfully!')

if __name__ == '__main__':
    main()

