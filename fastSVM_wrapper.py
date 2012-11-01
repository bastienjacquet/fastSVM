#!/usr/bin/env python

from ConfigParser import ConfigParser
import os
import sys
import subprocess
import boto
from boto.s3.key import Key
from PIL import Image

def main(argv):
    package = '/home/hadoop/contents/packaged.gz'

    parser = ConfigParser()
    parser.read('/home/hadoop/contents/.aws')
    aws_access_key_id = parser.get('Credentials', 'aws_access_key_id')
    aws_access_key_secret = parser.get('Credentials', 'aws_access_key_secret')

    connection = boto.connect_s3(
        aws_access_key_id=aws_access_key_id,
        aws_secret_access_key=aws_access_key_secret
    )
    bucket_in = connection.get_bucket('labeler')
    bucket_out = connection.get_bucket('fastsvm')
    
    env = os.environ
    env['LD_LIBRARY_PATH'] = '/usr/local/cuda/toolkit/lib64'

    for line in sys.stdin:
        line = line.strip()
        final = line.replace('.jpg', '.gz').replace('images', 'output_oct9')
        if bucket_out.get_key(final) is not None:
            print(line)
            continue
 
        d = os.path.split(line)
        try:
            os.makedirs(os.path.join('/home/hadoop/contents', d[0]))
        except:
            pass

        k = Key(bucket_in)
        k.key = line
        inputFile = os.path.join('/home/hadoop/contents', line)
        k.get_contents_to_filename(inputFile)
        output = inputFile.replace('.jpg', '.gz')
        sys.stderr.write('Input: %s\n'%inputFile)
        sys.stderr.write('Output: %s\n'%output)
        image = Image.open(inputFile)
        width, height = image.size
        maxSize = 960
        if width > maxSize or height > maxSize:
            if width > height:
                image = image.resize((960, int(960.0/width*height)))
            else:
                image = image.resize((int(960.0/height*width), 960))
            image.save(inputFile)
        proc = subprocess.Popen(['/home/hadoop/contents/fastSVM', inputFile, package, output], env=env, stdout=sys.stderr)
        retval = proc.wait()
        if retval != 0:
            exit(-1)
        k = Key(bucket_out)
        k.key = final 
        k.set_contents_from_filename(output)

        os.remove(inputFile)
        os.remove(output)
        print(line)
        sys.stderr.write('Done')

if __name__ == '__main__':
    main(sys.argv)
