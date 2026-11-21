'use strict';
// Read-only iOS 16 DDI diagnostics. Never logs pairing values or image signatures.
const fs = require('fs');
const net = require('net');
const tls = require('tls');
const crypto = require('crypto');

const [host, pairingPath] = process.argv.slice(2);
if (!host || !pairingPath) {
  console.error('Usage: node tools/diagnose-legacy-ddi.cjs <target-ip> <pairing.plist>');
  process.exit(1);
}
function text(xml, key, type = 'string') {
  const match = xml.match(new RegExp('<key>' + key + '</key>\\s*<' + type + '>([\\s\\S]*?)</' + type + '>'));
  return match ? match[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&') : undefined;
}
function bool(xml, key) {
  const match = xml.match(new RegExp('<key>' + key + '</key>\\s*<(true|false)\\s*/>'));
  return match ? match[1] === 'true' : undefined;
}
function encode(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function request(values) {
  return '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>' +
    Object.entries(values).map(([key, value]) => '<key>' + encode(key) + '</key><string>' + encode(value) + '</string>').join('') + '</dict></plist>';
}
function channel(socket) {
  let bytes = Buffer.alloc(0);
  let waiter;
  let failed;
  const fail = error => { failed = error; if (waiter) { const w = waiter; waiter = undefined; w.reject(error); } };
  const receive = chunk => {
    bytes = Buffer.concat([bytes, chunk]);
    if (bytes.length < 4 || !waiter) return;
    const length = bytes.readUInt32BE(0);
    if (length > 16 * 1024 * 1024) { fail(new Error('Invalid plist frame size')); return; }
    if (bytes.length < 4 + length) return;
    const xml = bytes.subarray(4, length + 4).toString('utf8');
    bytes = bytes.subarray(4 + length);
    const w = waiter; waiter = undefined; w.resolve(xml);
  };
  const end = () => fail(new Error('Peer closed before a complete plist response'));
  const timeout = () => { fail(new Error('Plist response timed out')); socket.destroy(); };
  socket.on('data', receive).on('error', fail).on('end', end).on('close', end).on('timeout', timeout);
  return {
    read() {
      if (failed) return Promise.reject(failed);
      if (waiter) return Promise.reject(new Error('Concurrent plist read'));
      return new Promise((resolve, reject) => { waiter = {resolve, reject}; receive(Buffer.alloc(0)); });
    },
    send(values) {
      const body = Buffer.from(request(values));
      const size = Buffer.alloc(4); size.writeUInt32BE(body.length);
      socket.write(Buffer.concat([size, body]));
    },
    async call(values) {
      const result = this.read();
      this.send(values);
      return result;
    },
    detach() {
      if (bytes.length || waiter) throw new Error('Cannot upgrade a busy plist channel');
      socket.off('data', receive).off('error', fail).off('end', end).off('close', end).off('timeout', timeout);
    }
  };
}
async function connect(port) {
  return await new Promise((resolve, reject) => {
    const socket = net.createConnection({host, port});
    socket.setTimeout(6000);
    const timeout = () => { socket.destroy(); reject(new Error('TCP connect timed out')); };
    socket.once('timeout', timeout).once('error', reject);
    socket.once('connect', () => { socket.off('timeout', timeout).off('error', reject); resolve(socket); });
  });
}
const pairing = fs.readFileSync(pairingPath, 'utf8');
if (!pairing.includes('<plist')) throw new Error('This diagnostic script requires an XML Lockdown plist');
const hostID = text(pairing, 'HostID');
const systemBUID = text(pairing, 'SystemBUID');
function certificate(key) {
  const encoded = text(pairing, key, 'data');
  if (!encoded) throw new Error('Pairing field missing: ' + key);
  return Buffer.from(encoded.replace(/\s+/g, ''), 'base64');
}
const cert = certificate('HostCertificate');
const key = certificate('HostPrivateKey');
const root = certificate('RootCertificate');
const deviceCertificate = new crypto.X509Certificate(certificate('DeviceCertificate'));
const secureContext = tls.createSecureContext({cert, key, ca: [root, deviceCertificate.toString()], minVersion: 'TLSv1.2'});
async function upgrade(socket) {
  return await new Promise((resolve, reject) => {
    // Authenticate the server against the pair record, without substituting a DNS identity.
    const secure = tls.connect({socket, host, secureContext, rejectUnauthorized: true,
      checkServerIdentity: (_name, peer) => peer.raw && peer.raw.equals(deviceCertificate.raw)
        ? undefined : new Error('Remote certificate does not match the pairing record')});
    const timeout = () => { secure.destroy(); reject(new Error('TLS handshake timed out')); };
    secure.setTimeout(6000);
    secure.once('timeout', timeout).once('error', reject);
    secure.once('secureConnect', () => {
      secure.off('timeout', timeout).off('error', reject);
      // Verify the pin explicitly as well, including TLS stacks skipping the hostname callback.
      if (!secure.getPeerCertificate().raw?.equals(deviceCertificate.raw)) {
        secure.destroy(); reject(new Error('Remote certificate pin mismatch')); return;
      }
      resolve(secure);
    });
  });
}
async function openControl() {
  let socket = await connect(62078);
  try {
    let messages = channel(socket);
    const session = await messages.call({Request: 'StartSession', Label: 'StikDebugReadOnlyDiagnostics', HostID: hostID, SystemBUID: systemBUID});
    checkError(session, 'StartSession');
    if (bool(session, 'EnableSessionSSL')) {
      messages.detach(); socket = await upgrade(socket); messages = channel(socket);
    }
    return {socket, messages};
  } catch (error) { socket.destroy(); throw error; }
}
function checkError(xml, command) {
  const error = text(xml, 'Error');
  if (error) throw new Error(command + ' returned ' + error);
}
(async () => {
  let control;
  let heartbeatSocket;
  let heartbeatTask;
  let stopping = false;
  let heartbeatReplies = 0;
  try {
    const initial = await openControl();
    control = initial.socket;
    const lockdown = initial.messages;
    for (const field of ['ProductVersion', 'ProductType']) {
      const response = await lockdown.call({Request: 'GetValue', Key: field});
      checkError(response, field);
      console.log('Remote ' + field + ': ' + text(response, 'Value'));
    }
    if (!process.argv.includes('--no-heartbeat')) {
      const attributes = await lockdown.call({Request: 'StartService', Service: 'com.apple.mobile.heartbeat'});
      checkError(attributes, 'StartService(heartbeat)');
      const heartbeatPort = Number(text(attributes, 'Port', 'integer'));
      heartbeatSocket = await connect(heartbeatPort);
      if (bool(attributes, 'EnableServiceSSL')) heartbeatSocket = await upgrade(heartbeatSocket);
      heartbeatSocket.setTimeout(20000);
      const heartbeat = channel(heartbeatSocket);
      let firstResolve, firstReject;
      const firstResponse = new Promise((resolve, reject) => { firstResolve = resolve; firstReject = reject; });
      heartbeatTask = (async () => {
        while (!stopping) {
          const marco = await heartbeat.read();
          const command = text(marco, 'Command');
          if (command === 'SleepyTime') throw new Error('Remote device heartbeat reported SleepyTime');
          heartbeat.send({Command: 'Polo'});
          heartbeatReplies++;
          firstResolve();
        }
      })().catch(error => { firstReject(error); if (!stopping) console.log('Heartbeat failed: ' + error.message); });
      await firstResponse;
      console.log('Heartbeat: Marco received, Polo sent; keeping session active.');
    }
    control.setTimeout(0); // Retain the heartbeat's originating control session while idle.
    const repeats = Math.min(10, Math.max(1, Number(process.argv.find(x => x.startsWith('--repeat='))?.split('=')[1] ?? 1)));
    const pause = Math.min(3000, Math.max(0, Number(process.argv.find(x => x.startsWith('--pause-ms='))?.split('=')[1] ?? 0)));
    for (const command of Array.from({length: repeats}, () => ['LookupImage', 'CopyDevices']).flat()) {
      let service;
      let serviceControl;
      try {
        const freshControl = await openControl();
        serviceControl = freshControl.socket;
        const serviceLockdown = freshControl.messages;
        const response = await serviceLockdown.call({Request: 'StartService', Service: 'com.apple.mobile.mobile_image_mounter'});
        checkError(response, 'StartService');
        const port = Number(text(response, 'Port', 'integer'));
        const ssl = bool(response, 'EnableServiceSSL') === true;
        if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid service port');
        console.log(command + ': endpoint=' + host + ':' + port + ', TLS=' + ssl);
        service = await connect(port);
        if (ssl) service = await upgrade(service);
        const mounter = channel(service);
        const keepalive = await serviceLockdown.call({Request: 'GetValue', Key: 'ProductVersion'});
        checkError(keepalive, 'Post-connect GetValue');
        const result = await mounter.call(command === 'LookupImage' ? {Command: command, ImageType: 'Developer'} : {Command: command});
        checkError(result, command);
        console.log(command + ': complete plist response; Status=' + (text(result, 'Status') ?? 'not provided') +
          '; signaturePresent=' + /<key>ImageSignature<\/key>\s*<array>\s*<data>/.test(result) +
          '; entryListPresent=' + /<key>EntryList<\/key>/.test(result));
      } catch (error) {
        console.log(command + ': FAILED: ' + error.message);
        process.exitCode = 1;
      } finally { service?.destroy(); serviceControl?.destroy(); }
      if (pause) await new Promise(resolve => setTimeout(resolve, pause));
    }
  } finally { stopping = true; heartbeatSocket?.destroy(); control?.destroy(); if (heartbeatTask) await heartbeatTask; console.log('Heartbeat replies sent: ' + heartbeatReplies); }
})().catch(error => { console.error('Read-only diagnostic failed: ' + error.message); process.exitCode = 1; });
