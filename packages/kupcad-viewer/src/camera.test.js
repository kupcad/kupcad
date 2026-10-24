import { Box3, PerspectiveCamera, Sphere, Vector3 } from 'three';
import { describe, expect, it } from 'vitest';
import { boundsOf, orthographicHalfHeight, perspectiveDistance, VIEWS } from './camera.js';
import { gridSide } from './environment.js';

/**
 * Where +Y and +Z of the model fall on the screen of a camera looking from `direction`.
 * @param {Vector3} direction
 */
const screenUp = (direction) => {
  const camera = new PerspectiveCamera();
  camera.up.set(0, 0, 1);
  camera.position.copy(direction).multiplyScalar(10);
  camera.lookAt(0, 0, 0);
  camera.updateMatrixWorld();
  return new Vector3(0, 1, 0).applyQuaternion(camera.quaternion);
};

describe('the views', () => {
  it('each look from a unit direction; top shows +Y up the screen, front +Z', () => {
    for (const direction of Object.values(VIEWS)) expect(direction.length()).toBeCloseTo(1, 12);
    expect(screenUp(VIEWS.top).y).toBeGreaterThan(0.99);
    expect(screenUp(VIEWS.front).z).toBeGreaterThan(0.99);
  });
});

describe('framing', () => {
  it('stands a perspective camera where the sphere fits its narrower angle, with a margin', () => {
    const sphere = new Sphere(new Vector3(), 10);
    // At 90 degrees and a square view, the radius spans 45 degrees
    expect(perspectiveDistance(sphere, 90, 1, 1)).toBeCloseTo(10 / Math.sin(Math.PI / 4), 9);
    // A tall view is narrower across than up: the width decides
    expect(perspectiveDistance(sphere, 90, 0.5, 1)).toBeGreaterThan(
      perspectiveDistance(sphere, 90, 1, 1),
    );
  });

  it('shows an orthographic camera as much as the sphere, the narrower side deciding', () => {
    const sphere = new Sphere(new Vector3(), 10);
    expect(orthographicHalfHeight(sphere, 2, 1)).toBe(10);
    expect(orthographicHalfHeight(sphere, 0.5, 1)).toBe(20);
  });

  it('frames a point when there is no model', () => {
    expect(boundsOf(new Box3()).radius).toBeGreaterThan(0);
  });
});

describe('the grid', () => {
  it('is a round size past twice the model, from the origin', () => {
    expect(gridSide(new Box3())).toBe(100);
    expect(gridSide(new Box3(new Vector3(0, 0, 0), new Vector3(20, 10, 2)))).toBe(50);
    expect(gridSide(new Box3(new Vector3(-80, 0, 0), new Vector3(20, 10, 2)))).toBe(200);
    expect(gridSide(new Box3(new Vector3(0, 0, 0), new Vector3(300, 10, 2)))).toBe(1000);
  });
});
