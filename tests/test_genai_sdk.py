"""
Tests for Google GenAI SDK integration.

Run with: pytest tests/test_genai_sdk.py -v
"""

import os
import pytest


def test_genai_import():
    """Test that the new google-genai SDK imports correctly."""
    from google import genai
    from google.genai import types

    assert hasattr(genai, 'Client')
    assert hasattr(types, 'GenerateContentConfig')
    assert hasattr(types, 'Part')


@pytest.mark.skipif(
    not os.environ.get('GEMINI_API_KEY') and not os.environ.get('GOOGLE_API_KEY'),
    reason="No API key set (GEMINI_API_KEY or GOOGLE_API_KEY)"
)
def test_genai_client_creation():
    """Test that we can create a GenAI client."""
    from google import genai

    # Client should be creatable (will use GEMINI_API_KEY env var)
    client = genai.Client()
    assert client is not None
    assert hasattr(client, 'models')


def test_types_part_from_bytes():
    """Test that Part.from_bytes works for audio data."""
    from google.genai import types

    # Create a fake audio byte payload
    fake_audio = b'\x00' * 100

    part = types.Part.from_bytes(data=fake_audio, mime_type="audio/wav")
    assert part is not None


def test_generate_content_config():
    """Test that GenerateContentConfig accepts our parameters."""
    from google.genai import types

    config = types.GenerateContentConfig(
        temperature=0.1,
        max_output_tokens=4000,
        response_mime_type="application/json",
    )
    assert config is not None


@pytest.mark.skipif(
    not os.environ.get('GEMINI_API_KEY') and not os.environ.get('GOOGLE_API_KEY'),
    reason="No API key set (GEMINI_API_KEY or GOOGLE_API_KEY)"
)
def test_simple_api_call():
    """Test a simple API call to verify credentials work."""
    from google import genai
    from google.genai import types

    client = genai.Client()

    response = client.models.generate_content(
        model="gemini-3-flash-preview",
        contents="Say 'hello' and nothing else.",
        config=types.GenerateContentConfig(
            temperature=0.0,
            max_output_tokens=100,  # Need enough for model's thinking tokens
        ),
    )

    assert response is not None
    assert response.text is not None
    assert len(response.text) > 0


@pytest.mark.skipif(
    not os.environ.get('GEMINI_API_KEY') and not os.environ.get('GOOGLE_API_KEY'),
    reason="No API key set (GEMINI_API_KEY or GOOGLE_API_KEY)"
)
def test_json_response_mode():
    """Test JSON response mode works correctly."""
    from google import genai
    from google.genai import types
    import json
    import re

    client = genai.Client()

    response = client.models.generate_content(
        model="gemini-3-flash-preview",
        contents='Return ONLY a JSON object with a single key "status" and value "ok". No other text.',
        config=types.GenerateContentConfig(
            temperature=0.0,
            response_mime_type="application/json",
        ),
    )

    assert response is not None
    assert response.text is not None

    # Extract JSON from response (model may include preamble)
    text = response.text.strip()
    # Try to find JSON object in the response
    json_match = re.search(r'\{[^}]+\}', text)
    if json_match:
        text = json_match.group(0)

    data = json.loads(text)
    assert "status" in data
