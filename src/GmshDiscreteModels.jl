
const D3=3
const POINT=15
const UNSET = 0

function GmshDiscreteModel(mshfile)

  if !isfile(mshfile)
    error("Msh file not found: $mshfile")
  end

  gmsh.initialize()
  gmsh.option.setNumber("General.Terminal", 1)
  gmsh.open(mshfile)

  D = _setup_dim(gmsh)

  node_to_coords = _setup_node_coords(gmsh,D)

  grid, cell_to_entity = _setup_grid(gmsh,D,node_to_coords)

  dim_to_gface_to_nodes, dim_gface_to_entity = _setup_faces(gmsh,D)

  push!(dim_to_gface_to_nodes,cells(grid))
  push!(dim_gface_to_entity,cell_to_entity)

  dim_to_group_to_entities = _setup_dim_to_group_to_entities(gmsh)

  dim_to_group_to_name = _setup_dim_to_group_to_name(gmsh)

  dim_to_offset = _setup_dim_to_offset(gmsh)

  gmsh.finalize()

  graph = FullGridGraph(grid)

  facelabels = _setup_face_labels(
    graph,
    dim_to_gface_to_nodes,
    dim_gface_to_entity,
    dim_to_offset,
    dim_to_group_to_entities,
    dim_to_group_to_name)

  grids = _setup_model_grids(graph,grid,D)

  DiscreteModelFromData( grids, graph, facelabels)

end

function _setup_grid(gmsh,D,node_to_coords)

  cell_to_nodes, nminD, cell_to_extrusion, cell_to_order =
    _setup_connectivity(gmsh,D)

  grid = UnstructuredGrid(
    node_to_coords,
    cell_to_nodes.data,
    cell_to_nodes.ptrs,
    cell_to_extrusion,
    cell_to_order)

  cell_to_entity = _setup_cell_to_entity(
    gmsh,D,length(cell_to_nodes),nminD)

  (grid, cell_to_entity)

end

function _setup_faces(gmsh,D)

  dim_to_gface_to_nodes = []
  dim_gface_to_entity = []

  for d in 0:(D-1)
    face_to_nodes, nmin, _, _ = _setup_connectivity(gmsh,d)
    face_to_entity = _setup_cell_to_entity(gmsh,d,length(face_to_nodes),nmin)
    push!(dim_to_gface_to_nodes,face_to_nodes)
    push!(dim_gface_to_entity,face_to_entity)
  end

  (dim_to_gface_to_nodes, dim_gface_to_entity)

end

function _setup_dim_to_group_to_entities(gmsh)
  dim_to_group_to_entities = Vector{Vector{Int}}[]
  for d in 0:D3
    pgs = gmsh.model.getPhysicalGroups(d)
    n = length(pgs)
    group_to_entities = Vector{Int}[]
    for (i,pg) in enumerate(pgs)
      es = gmsh.model.getEntitiesForPhysicalGroup(pg...)
      entities = Int[]
      for e in es
        push!(entities,e)
      end
      push!(group_to_entities,entities)
    end
    push!(dim_to_group_to_entities,group_to_entities)
  end
  dim_to_group_to_entities
end

function _setup_dim_to_group_to_name(gmsh)
  u = 1
  dim_to_group_to_name = Vector{String}[]
  for d in 0:D3
    pgs = gmsh.model.getPhysicalGroups(d)
    n = length(pgs)
    names = String[]
    for (i,pg) in enumerate(pgs)
      _name = gmsh.model.getPhysicalName(d,i)
      if _name == ""
        name = "untitled$u"
        u += 1
      else
        name = _name
      end
      push!(names,name)
    end
    push!(dim_to_group_to_name,names)
  end
  dim_to_group_to_name
end

function _setup_face_labels(
  graph,
  dim_to_gface_to_nodes,
  dim_gface_to_entity,
  dim_to_offset,
  dim_to_group_to_entities,
  dim_to_group_to_name)

  D = ndims(graph)

  dim_to_face_to_label = [
    fill(UNSET,length(connections(graph,d,0))) for d in 0:D ]

  tag_to_labels = _setup_tag_to_labels(
    dim_to_group_to_entities,dim_to_offset)

  tag_to_name = _setup_tag_to_name(dim_to_group_to_name)

  FaceLabels(dim_to_face_to_label,tag_to_labels,tag_to_name)

end

function _setup_tag_to_labels(dim_to_group_to_entities,dim_to_offset)
  tag_to_labels = Vector{Int}[]
  for (dim,group_to_entities) in enumerate(dim_to_group_to_entities)
    offset = dim_to_offset[dim]
    for entities in group_to_entities
      n = length(entities)
      labels = zeros(Int,n)
      for i in 1:n
        labels[i] = entities[i] + offset
      end
      push!(tag_to_labels,labels)
    end
  end
  tag_to_labels
end

function _setup_tag_to_name(dim_to_group_to_name)
  tag_to_name = String[]
  for group_to_name in dim_to_group_to_name
    for name in group_to_name
      push!(tag_to_name,name)
    end
  end
  tag_to_name
end

function _setup_dim_to_offset(gmsh)
  entities = gmsh.model.getEntities()
  dim_to_nentities = zeros(Int,D3+1)
  for e in entities
    d = e[1]
    dim_to_nentities[d+1] += 1
  end
  dim_to_offset = zeros(Int,D3+1)
  for d=1:D3
    dim_to_offset[d+1] += dim_to_nentities[d-1+1] + dim_to_offset[d-1+1]
  end
  dim_to_offset
end

function _setup_dim(gmsh)
  entities = gmsh.model.getEntities()
  D = -1
  for e in entities
    D = max(D,e[1])
  end
  if D == -1
    gmsh.finalize()
    error("No entities in the msh file.")
  end
  D
end

function _setup_cell_to_entity(gmsh,d,ncells,nmin)

  cell_to_entity = zeros(Int,ncells)
  entities = gmsh.model.getEntities(d)
  for e in entities
    _, elemTags, _ = gmsh.model.mesh.getElements(e[1], e[2])
    _fill_cell_to_entity!(cell_to_entity,elemTags,e[2],nmin-1)
  end

  cell_to_entity

end

function _fill_cell_to_entity!(cell_to_entity,elemTags,entity,o)

  for i_to_cell in elemTags
    for cell in i_to_cell
      cell_to_entity[cell-o] = entity
    end
  end

end

function _setup_model_grids(graph,grid,D)

  grids = Grid[]

  order = cellorders(grid).value
  extrusionD = celltypes(grid).value
  node_to_coords = points(grid)

  for d in 0:(D-1)

    grid_d = _setup_grid_from_graph(graph,d,node_to_coords,extrusionD,order)
    push!(grids,grid_d)

  end

  push!(grids,grid)

  grids

end

function _setup_grid_from_graph(graph,d,node_to_coords,extrusionD,order)

  if !all(extrusionD .== extrusionD[1])
    gmsh.finalize()
    error("Only lines, tris, quads, tets, and hexs allowed for the moment.")
  end

  extrusion = extrusionD[1:d]
  face_to_nodes = connections(graph,d,0)
  n = length(face_to_nodes)
  face_to_extrusion = ConstantCellValue(extrusion,n)
  face_to_order = ConstantCellValue(order,n)

  UnstructuredGrid(
    node_to_coords,
    face_to_nodes.data,
    face_to_nodes.ptrs,
    face_to_extrusion,
    face_to_order)

end

function _setup_node_coords(gmsh,D)

  nodeTags, coord, parametricCoord = gmsh.model.mesh.getNodes()

  nmin = minimum(nodeTags)
  nmax = maximum(nodeTags)
  nnodes = length(nodeTags)

  if !(nmax == nnodes && nmin == 1)
    gmsh.finalize()
    error("Only consecutive node tags allowed.")
  end

  node_to_coords = zeros(Point{D,Float64},nnodes)
  _fill_node_coords!(node_to_coords,nodeTags,coord,D)

  node_to_coords

end

function _fill_node_coords!(node_to_coords,nodeTags,coord,D)

  m = zero(MVector{D,Float64})

  for node in nodeTags
    for j in 1:D
      k = (node-1)*D3 + j
      xj = coord[k]
      m[j] = xj
    end
    node_to_coords[node] = m
  end

end

function _check_cell_tags(elemTags)
  nmin::Int = minimum([minimum(t) for t in elemTags])
  nmax::Int = maximum([maximum(t) for t in elemTags])
  ncells = sum([length(t) for t in elemTags])
  if !( (nmax-nmin+1) == ncells)
    gmsh.finalize()
    error("Only consecutive elem tags allowed.")
  end
  (ncells,nmin,nmax)
end

function _setup_connectivity(gmsh,d)

  elemTypes, elemTags, nodeTags = gmsh.model.mesh.getElements(d)

  ncells, nmin, nmax = _check_cell_tags(elemTags)
  ndata = sum([length(t) for t in nodeTags])
  etype_to_nlnodes = _setup_etype_to_nlnodes(elemTypes,gmsh)

  cell_to_nodes_prts = zeros(Int,ncells+1)
  cell_to_nodes_data = zeros(Int,ndata)

  _fill_connectivity!(
    cell_to_nodes_data,
    cell_to_nodes_prts,
    nmin-1,
    etype_to_nlnodes,
    elemTypes,
    elemTags,
    nodeTags)

  cell_to_nodes = CellVectorFromDataAndPtrs(cell_to_nodes_data,cell_to_nodes_prts)

  if !(length(elemTypes)==1)
    gmsh.finalize()
    s = """
    Only one element type per dimension allowed for the moment.
    Dimension $d has $(length(elemTypes)) different element types
    """
    error(s)
  end

  etype::Int = elemTypes[1]
  name, dim, order::Int, numv, parv = gmsh.model.mesh.getElementProperties(etype)
  extrusion = _extrussion_from_etype(Val(etype))
  if extrusion == nothing
    gmsh.finalize()
    error("Unsupported element type. elemType: $etype")
  end

  if order == 0 && etype == POINT
    order = 1
  end

  cell_to_extrusion = ConstantCellValue(extrusion,ncells)
  cell_to_order = ConstantCellValue(order,ncells)

  (cell_to_nodes, nmin, cell_to_extrusion, cell_to_order)

end

const t = TET_AXIS
const h = HEX_AXIS
_extrussion_from_etype(::Val{1}) = (h,)
_extrussion_from_etype(::Val{2}) = (t,t)
_extrussion_from_etype(::Val{3}) = (h,h)
_extrussion_from_etype(::Val{4}) = (t,t,t)
_extrussion_from_etype(::Val{5}) = (h,h,h)
_extrussion_from_etype(::Val{POINT}) = ()
_extrussion_from_etype(v) = nothing

function  _fill_connectivity!(
    cell_to_nodes_data,
    cell_to_nodes_prts,
    o,
    etype_to_nlnodes,
    elemTypes,
    elemTags,
    nodeTags)

  for (j,etype) in enumerate(elemTypes)
    nlnodes = etype_to_nlnodes[etype]
    i_to_cell = elemTags[j]
    for cell in i_to_cell
      cell_to_nodes_prts[cell+1-o] = nlnodes
    end
  end

  length_to_ptrs!(cell_to_nodes_prts)

  for (j,etype) in enumerate(elemTypes)
    nlnodes = etype_to_nlnodes[etype]
    i_to_cell = elemTags[j]
    i_lnode_to_node = nodeTags[j]
    for (i,cell) in enumerate(i_to_cell)
      a = cell_to_nodes_prts[cell-o]-1
      for lnode in 1:nlnodes
        node = i_lnode_to_node[(i-1)*nlnodes+lnode]
        cell_to_nodes_data[a+lnode] = node
      end
    end
  end

end

function _setup_etype_to_nlnodes(elemTypes,gmsh)
  netypes = maximum(elemTypes)
  etype_to_nlnodes = zeros(Int,netypes)
  for etype in elemTypes
    name, dim, order, numv, parv =
      gmsh.model.mesh.getElementProperties(etype)
    etype_to_nlnodes[etype] = numv
  end
  etype_to_nlnodes
end

