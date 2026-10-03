/*
 *  Sundog FairPlay interface for AirPlay mirroring.
 *  The implementation uses the playfair code from UxPlay (GPL-3.0).
 */
#ifndef SUNDOG_FAIRPLAY_H
#define SUNDOG_FAIRPLAY_H

/* Answers the first fp-setup request (16 bytes) with 142 bytes. Returns 0 on success. */
int sundog_fairplay_setup(const unsigned char request[16], unsigned char response[142]);

/* Answers the second fp-setup request (164 bytes) with 32 bytes. Returns 0 on success.
 * Keep the 164-byte request: it is the key message for sundog_fairplay_decrypt. */
int sundog_fairplay_handshake(const unsigned char request[164], unsigned char response[32]);

/* Decrypts the 72-byte "ekey" from SETUP into the 16-byte AES key. */
void sundog_fairplay_decrypt(const unsigned char key_message[164], const unsigned char encrypted_key[72], unsigned char key[16]);

#endif
