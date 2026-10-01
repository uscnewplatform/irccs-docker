#!/usr/bin/env python3
"""
Test di unità per la verifica crittografica di integrità dell'audit trail.
"""
import copy
import json
import os
import unittest
from verify_audit_hash_chain import (
    canonical_payload,
    sha256_hex,
    verify_single_event,
    EXT_PREV,
    EXT_HASH,
)


class TestAuditIntegrityVerifier(unittest.TestCase):

    def setUp(self):
        self.sample_event_1 = {
            "resourceType": "AuditEvent",
            "id": "1001",
            "recorded": "2026-09-01T10:00:00.000Z",
            "action": "C",
            "outcome": "0",
            "type": {
                "system": "http://terminology.hl7.org/CodeSystem/audit-event-type",
                "code": "rest"
            },
            "subtype": [
                {
                    "system": "http://hl7.org/fhir/restful-interaction",
                    "code": "create"
                }
            ],
            "agent": [
                {
                    "who": {
                        "identifier": {
                            "system": "http://irccs.pascale.it/iam/user",
                            "value": "mrossi@irccs.it"
                        }
                    },
                    "network": {
                        "address": "192.168.1.50"
                    }
                }
            ],
            "entity": [
                {
                    "what": {
                        "reference": "Patient/pat-001"
                    },
                    "detail": [
                        {
                            "type": "operation",
                            "valueString": "Creazione anagrafica paziente"
                        }
                    ]
                }
            ],
            "source": {
                "site": "irccs-anagrafica-pazienti"
            }
        }

    def test_canonical_payload_formatting(self):
        payload = canonical_payload(self.sample_event_1)
        expected = (
            "recorded=2026-09-01T10:00:00.000Z;"
            "action=C;"
            "outcome=0;"
            "type=http://terminology.hl7.org/CodeSystem/audit-event-type|rest;"
            "subtype=create;"
            "agent=http://irccs.pascale.it/iam/user|mrossi@irccs.it@192.168.1.50;"
            "entity=Patient/pat-001detail=Creazione anagrafica paziente,;"
            "site=irccs-anagrafica-pazienti"
        )
        self.assertEqual(payload, expected)

    def test_valid_chain_two_events(self):
        # Evento 1
        ev1 = copy.deepcopy(self.sample_event_1)
        prev1 = ""
        canon1 = canonical_payload(ev1)
        hash1 = sha256_hex(f"{prev1}|{canon1}")
        ev1["extension"] = [
            {"url": EXT_PREV, "valueString": prev1},
            {"url": EXT_HASH, "valueString": hash1}
        ]

        # Evento 2
        ev2 = {
            "resourceType": "AuditEvent",
            "id": "1002",
            "recorded": "2026-09-01T10:05:00.000Z",
            "action": "R",
            "outcome": "0",
            "type": {
                "system": "http://terminology.hl7.org/CodeSystem/audit-event-type",
                "code": "rest"
            },
            "subtype": [
                {"code": "read"}
            ],
            "agent": [
                {
                    "who": {
                        "identifier": {
                            "system": "http://irccs.pascale.it/iam/user",
                            "value": "gverdi@irccs.it"
                        }
                    },
                    "network": {
                        "address": "192.168.1.60"
                    }
                }
            ],
            "entity": [
                {
                    "what": {
                        "reference": "Patient/pat-001"
                    }
                }
            ],
            "source": {
                "site": "irccs-anagrafica-pazienti"
            }
        }
        prev2 = hash1
        canon2 = canonical_payload(ev2)
        hash2 = sha256_hex(f"{prev2}|{canon2}")
        ev2["extension"] = [
            {"url": EXT_PREV, "valueString": prev2},
            {"url": EXT_HASH, "valueString": hash2}
        ]

        # Verifica Evento 1
        ok1, exp_hash1, act_hash1, err1 = verify_single_event(ev1, expected_prev=None)
        self.assertTrue(ok1, f"Evento 1 doveva essere valido: {err1}")
        self.assertEqual(exp_hash1, hash1)

        # Verifica Evento 2 con expected_prev = hash1
        ok2, exp_hash2, act_hash2, err2 = verify_single_event(ev2, expected_prev=hash1)
        self.assertTrue(ok2, f"Evento 2 doveva essere valido: {err2}")
        self.assertEqual(exp_hash2, hash2)

    def test_tamper_detection_modified_user(self):
        ev = copy.deepcopy(self.sample_event_1)
        prev = "someprevioushash"
        canon = canonical_payload(ev)
        original_hash = sha256_hex(f"{prev}|{canon}")
        ev["extension"] = [
            {"url": EXT_PREV, "valueString": prev},
            {"url": EXT_HASH, "valueString": original_hash}
        ]

        # Simula un'alterazione illecita su Postgres: cambio utente
        ev["agent"][0]["who"]["identifier"]["value"] = "hacker@evil.org"

        ok, exp_hash, act_hash, err = verify_single_event(ev, expected_prev=prev)
        self.assertFalse(ok)
        self.assertIn("Alterazione contenuto/Tamper", err)
        self.assertNotEqual(exp_hash, act_hash)

    def test_tamper_detection_modified_detail(self):
        ev = copy.deepcopy(self.sample_event_1)
        prev = ""
        canon = canonical_payload(ev)
        original_hash = sha256_hex(f"{prev}|{canon}")
        ev["extension"] = [
            {"url": EXT_PREV, "valueString": prev},
            {"url": EXT_HASH, "valueString": original_hash}
        ]

        # Simula modifica del testo dell'operazione
        ev["entity"][0]["detail"][0]["valueString"] = "Modifica furtiva senza traccia"

        ok, exp_hash, act_hash, err = verify_single_event(ev, expected_prev=prev)
        self.assertFalse(ok)
        self.assertIn("Alterazione contenuto/Tamper", err)

    def test_chain_break_detection(self):
        ev = copy.deepcopy(self.sample_event_1)
        # L'evento dichiara un prev diverso da quello che la sequenza temporale si aspetta
        ev["extension"] = [
            {"url": EXT_PREV, "valueString": "wrongprevioushash"},
            {"url": EXT_HASH, "valueString": "somehash"}
        ]
        ok, exp_hash, act_hash, err = verify_single_event(ev, expected_prev="expectedhash123")
        self.assertFalse(ok)
        self.assertIn("Rottura catena", err)


if __name__ == "__main__":
    unittest.main()
