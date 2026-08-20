import http.server, socketserver, os
os.chdir(r'C:/Users/giuse/Projects/miao/scripts/sshkey-deb/www')
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('0.0.0.0', 8765), H) as httpd:
    print('Serving', os.getcwd(), 'on 0.0.0.0:8765', flush=True)
    httpd.serve_forever()